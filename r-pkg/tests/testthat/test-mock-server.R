test_that("mock server entry points skip before starting subprocesses on CRAN", {
  withr::local_envvar(NOT_CRAN = "false")

  expect_condition(start_mock_server_local(), "On CRAN", class = "skip")
  expect_condition(start_mock_server_tcp(), "On CRAN", class = "skip")
  expect_condition(
    with_mock_jgd(stop("must not run")),
    "On CRAN",
    class = "skip"
  )
  expect_condition(
    with_mock_jgd(stop("must not run"), transport = "tcp"),
    "On CRAN",
    class = "skip"
  )
})

test_that("collection reports unknown and nonzero exit statuses", {
  # Unknown statuses are rare in real processx processes, so model them here.
  for (status in list(NULL, NA_integer_, 1L)) {
    bg = list(
      wait = function(timeout) NULL,
      is_alive = function() FALSE,
      get_exit_status = function() status,
      read_error = function() "server diagnostic",
      get_result = function() stop("must not read a failed result")
    )
    message = if (is.null(status) || is.na(status)) {
      "unknown exit status: server diagnostic"
    } else {
      "error \\(status 1\\): server diagnostic"
    }
    expect_error(collect_mock_server(bg, 1), message)
  }
})

test_that("local collection timeout terminates the waiting mock server", {
  server = start_mock_server_local()
  withr::defer(server$cleanup())

  expect_error(server$collect(timeout = 1), "Mock server timed out after 1 ms")
  expect_false(server$bg$is_alive())
})

test_that("TCP collection timeout terminates the waiting mock server", {
  server = start_mock_server_tcp()
  withr::defer(server$cleanup())

  expect_error(
    server$collect(timeout = 1),
    "Mock TCP server timed out after 1 ms"
  )
  expect_false(server$bg$is_alive())
})

test_that("collection reports a terminated subprocess for both transports", {
  lapply(list(start_mock_server_local, start_mock_server_tcp), function(start) {
    server = start()
    withr::defer(server$cleanup())
    server$bg$kill()

    expect_error(server$collect(), "exited with error \\(status")
  })
})

test_that("local readiness waits for socket creation to return", {
  skip_on_cran()
  skip_if_not_installed("callr")
  skip_if_not_installed("processx")
  skip_if_not_installed("jsonlite")

  returned_file = withr::local_tempfile()
  files = new.env(parent = emptyenv())
  r_bg = callr::r_bg
  local_mocked_bindings(
    r_bg = function(func, args, ...) {
      files$ready = args$ready_file
      r_bg(
        function(func, args, returned_file) {
          create_socket = processx::conn_create_unix_socket
          # Delay the constructor after the socket/pipe exists. The parent must
          # still wait until the constructor returns and publishes readiness.
          assignInNamespace(
            "conn_create_unix_socket",
            function(...) {
              server = create_socket(...)
              Sys.sleep(0.5)
              writeLines("returned", returned_file)
              server
            },
            ns = "processx"
          )
          do.call(func, args)
        },
        args = list(func = func, args = args, returned_file = returned_file),
        ...
      )
    },
    .package = "callr"
  )

  run_server = function() {
    server = start_mock_server_local()
    withr::defer(if (server$bg$is_alive()) server$bg$kill())
    expect_true(file.exists(returned_file))
    expect_true(file.exists(files$ready))

    jgd(socket = server$socket_path)
    dev.off()
    expect_identical(tail(server$collect(), 1)[[1]]$type, "close")
    server$socket_path
  }
  socket_path = run_server()
  # withr removes the paths when the caller finishes, even without
  # an explicit server$cleanup() call.
  expect_false(file.exists(files$ready))
  if (.Platform$OS.type != "windows") {
    expect_false(file.exists(socket_path))
  }
})
