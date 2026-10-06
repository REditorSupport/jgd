# Mock JSON servers for jgd testthat tests
#
# Two transport variants:
#   start_mock_server_local() — local IPC socket via processx (Unix domain socket
#                              on Unix, Windows named pipe on Windows)
#   start_mock_server_tcp()  — TCP socket (base R), works on all platforms
#
# Both run a background R process (via callr::r_bg) that:
# 1. Listens on a socket
# 2. Accepts one jgd device connection
# 3. Responds to metrics_request messages with approximate values
# 4. Collects all received JSON messages
# 5. Returns collected messages when the device sends "close"
#
# These subprocess/socket integration tests run in CI, but are skipped on CRAN.

# Shared by both transports: wait() does not terminate a process on timeout.
collect_mock_server = function(bg, timeout, name = "Mock server") {
  bg$wait(timeout)
  if (bg$is_alive()) {
    bg$kill()
    stop(name, " timed out after ", timeout,
         " ms waiting for completion; background process terminated")
  }

  status = bg$get_exit_status()
  read_error = function() {
    # kill() can close stderr; preserve the exit-status error in that case.
    tryCatch(bg$read_error(), error = function(e) "stderr unavailable")
  }
  if (is.null(status) || is.na(status)) {
    stop(name, " exited with unknown exit status: ", read_error())
  }
  if (status != 0) {
    stop(name, " exited with error (status ", status, "): ", read_error())
  }
  bg$get_result()
}

start_mock_server_local = function(
  send_welcome = FALSE,
  transport = "unix",
  envir = parent.frame()
) {
  skip_on_cran()
  skip_if_not_installed("callr")
  skip_if_not_installed("processx")
  skip_if_not_installed("jsonlite")

  is_windows = (.Platform$OS.type == "windows")
  # Keep paths until the caller finishes, rather than until this helper returns.
  ready_file = withr::local_tempfile(
    pattern = "jgd-test-ready-", fileext = ".txt", .local_envir = envir
  )

  if (is_windows) {
    # Windows: named pipe via processx
    pipe_name = sprintf("jgd-test-%d-%s", Sys.getpid(),
                        basename(ready_file))
    # processx expects \\?\pipe\NAME (extended-length path prefix);
    # the C client uses \\.\pipe\NAME (device namespace) — both resolve
    # to the same kernel pipe object
    win_path = paste0("\\\\?\\pipe\\", pipe_name)
  } else {
    socket_path = tempfile(pattern = "jgd-test-", fileext = ".sock")
    # local_tempfile() uses recursive unlink, which does not remove Unix sockets.
    withr::defer(unlink(socket_path), envir = envir)
  }

  bg = callr::r_bg(
    function(conn_path, ready_file, send_welcome, transport) {
      `%||%` = function(x, y) if (is.null(x)) y else x
      server = processx::conn_create_unix_socket(conn_path)

      # On Windows the first poll starts ConnectNamedPipe. Arm it before a
      # fast client can connect and close, leaving an unaccepted closed pipe.
      processx::poll(list(server), 0)

      # Signal readiness only after socket creation (including listen) returns.
      # The Unix socket path can appear before the server is listening.
      writeLines("ready", ready_file)

      # Wait for client connection (30s timeout)
      # poll() returns "connect" (not "ready") for new connections on a
      # listening Unix socket / named pipe
      res = processx::poll(list(server), 30000)
      if (!res[[1L]] %in% c("ready", "connect")) {
        stop("No client connected within 30s (poll returned: ", res[[1L]], ")")
      }
      processx::conn_accept_unix_socket(server)

      welcome_sent = FALSE
      messages = list()
      repeat {
        res = processx::poll(list(server), 5000)
        if (!res[[1L]] %in% c("ready", "connect")) {
          next
        }

        lines = processx::conn_read_lines(server)
        for (line in lines) {
          if (!nzchar(line)) {
            next
          }
          msg = jsonlite::fromJSON(line, simplifyVector = FALSE)
          messages = c(messages, list(msg))

          # Send server_info welcome after receiving the first message
          if (send_welcome && !welcome_sent) {
            welcome = list(
              type = "server_info",
              serverName = "jgd-mock",
              protocolVersion = 1L,
              transport = transport,
              serverInfo = list(httpUrl = "http://127.0.0.1:9999/")
            )
            processx::conn_write(
              server,
              paste0(jsonlite::toJSON(welcome, auto_unbox = TRUE), "\n")
            )
            welcome_sent = TRUE
          }

          # Respond to metrics_request so tests run fast
          if (identical(msg$type, "metrics_request")) {
            resp = if (identical(msg$kind, "strWidth")) {
              list(
                type = "metrics_response",
                id = msg$id,
                width = nchar(msg$str %||% "") * 8.0
              )
            } else {
              list(
                type = "metrics_response",
                id = msg$id,
                ascent = 10.0,
                descent = 3.0,
                width = 8.0
              )
            }
            processx::conn_write(
              server,
              paste0(jsonlite::toJSON(resp, auto_unbox = TRUE), "\n")
            )
          }

          if (identical(msg$type, "close")) break
        }

        # Exit loop after close
        if (
          length(messages) > 0 &&
            identical(messages[[length(messages)]]$type, "close")
        ) {
          break
        }
      }

      close(server)
      messages
    },
    args = list(
      conn_path = if (is_windows) win_path else socket_path,
      ready_file = ready_file,
      send_welcome = send_welcome,
      transport = transport
    ),
    supervise = TRUE
  )

  # Both Unix sockets and Windows named pipes use an explicit readiness signal.
  for (i in seq_len(30)) {
    if (file.exists(ready_file)) break
    Sys.sleep(0.1)
  }
  if (!file.exists(ready_file)) {
    bg$kill()
    unlink(ready_file)
    if (!is_windows) unlink(socket_path)
    skip("Mock server not ready in time")
  }
  if (is_windows) {
    client_uri = paste0("npipe:////./pipe/", pipe_name)
  } else {
    client_uri = socket_path
  }

  list(
    bg = bg,
    socket_path = client_uri,
    collect = function(timeout = 10000) {
      collect_mock_server(bg, timeout)
    },
    cleanup = function() {
      if (bg$is_alive()) {
        bg$kill()
      }
      if (!is_windows) {
        unlink(socket_path)
      }
      unlink(ready_file)
    }
  )
}

# TCP mock server using base R sockets (works on all platforms including Windows)
start_mock_server_tcp = function(
  send_welcome = FALSE,
  transport = "tcp",
  envir = parent.frame()
) {
  skip_on_cran()
  skip_if_not_installed("callr")
  skip_if_not_installed("jsonlite")

  port_file = withr::local_tempfile(
    pattern = "jgd-tcp-port-", fileext = ".txt", .local_envir = envir
  )

  bg = callr::r_bg(
    function(port_file, send_welcome, transport) {
      `%||%` = function(x, y) if (is.null(x)) y else x
      # Find a free port and start listening
      server = NULL
      port = NULL
      for (i in seq_len(20)) {
        candidate = sample(10000L:60000L, 1L)
        result = tryCatch(serverSocket(candidate), error = function(e) NULL)
        if (!is.null(result)) {
          server = result
          port = candidate
          break
        }
      }
      if (is.null(port)) {
        stop("Could not find free port for TCP mock server")
      }

      on.exit(close(server), add = TRUE)

      # Signal readiness with port number
      writeLines(as.character(port), port_file)

      # Accept one client connection
      conn = socketAccept(server, blocking = TRUE, open = "r+")
      on.exit(close(conn), add = TRUE)

      welcome_sent = FALSE
      messages = list()
      repeat {
        ready = socketSelect(list(conn), timeout = 5)
        if (!ready) {
          next
        }

        line = readLines(conn, n = 1)
        if (length(line) == 0 || !nzchar(line)) {
          next
        }

        msg = jsonlite::fromJSON(line, simplifyVector = FALSE)
        messages = c(messages, list(msg))

        # Send server_info welcome after receiving the first message
        if (send_welcome && !welcome_sent) {
          welcome = list(
            type = "server_info",
            serverName = "jgd-mock",
            protocolVersion = 1L,
            transport = transport,
            serverInfo = list(httpUrl = "http://127.0.0.1:9999/")
          )
          writeLines(jsonlite::toJSON(welcome, auto_unbox = TRUE), conn)
          flush(conn)
          welcome_sent = TRUE
        }

        # Respond to metrics_request so tests run fast
        if (identical(msg$type, "metrics_request")) {
          resp = if (identical(msg$kind, "strWidth")) {
            list(
              type = "metrics_response",
              id = msg$id,
              width = nchar(msg$str %||% "") * 8.0
            )
          } else {
            list(
              type = "metrics_response",
              id = msg$id,
              ascent = 10.0,
              descent = 3.0,
              width = 8.0
            )
          }
          writeLines(jsonlite::toJSON(resp, auto_unbox = TRUE), conn)
          flush(conn)
        }

        if (identical(msg$type, "close")) break
      }

      messages
    },
    args = list(port_file = port_file, send_welcome = send_welcome, transport = transport),
    supervise = TRUE
  )

  # Wait for the port file to appear (server is listening)
  port = NULL
  for (i in seq_len(50)) {
    if (file.exists(port_file)) {
      port_str = readLines(port_file, n = 1, warn = FALSE)
      if (length(port_str) > 0 && nzchar(port_str)) {
        port = as.integer(port_str)
        break
      }
    }
    Sys.sleep(0.1)
  }
  if (is.null(port)) {
    bg$kill()
    skip("Mock TCP server did not start in time")
  }

  list(
    bg = bg,
    port = port,
    socket_url = sprintf("tcp://127.0.0.1:%d", port),
    collect = function(timeout = 10000) {
      collect_mock_server(bg, timeout, "Mock TCP server")
    },
    cleanup = function() {
      if (bg$is_alive()) {
        bg$kill()
      }
      unlink(port_file)
    }
  )
}

# Convenience: open jgd device connected to mock server, run expr, close,
# and return all captured JSON messages.
with_mock_jgd = function(
  expr,
  width = 4,
  height = 3,
  dpi = 72,
  transport = c("unix", "tcp"),
  send_welcome = FALSE
) {
  transport = match.arg(transport)
  if (transport == "tcp") {
    server = start_mock_server_tcp(send_welcome = send_welcome)
    socket_addr = server$socket_url
  } else {
    server = start_mock_server_local(send_welcome = send_welcome)
    socket_addr = server$socket_path
  }
  withr::defer(server$cleanup())

  jgd(width = width, height = height, dpi = dpi, socket = socket_addr)
  force(expr)
  dev.off()

  server$collect()
}

# Extract frame messages from a list of collected messages
extract_frames = function(msgs) {
  Filter(function(m) identical(m$type, "frame"), msgs)
}

# Extract all ops across all frames
extract_ops = function(msgs) {
  frames = extract_frames(msgs)
  unlist(lapply(frames, function(f) f$plot$ops), recursive = FALSE)
}

# Extract ops of a specific type
extract_ops_by_type = function(msgs, op_type) {
  ops = extract_ops(msgs)
  Filter(function(o) identical(o$op, op_type), ops)
}

# Write a discovery file to a temporary directory and mock jgd_cache_dir()
# to point there. Returns the temporary cache dir path.
write_test_discovery = function(json_content, envir = parent.frame()) {
  cache_dir = withr::local_tempdir("jgd-cache-", .local_envir = envir)
  jgd_dir = file.path(cache_dir, "jgd")
  dir.create(jgd_dir, recursive = TRUE)
  writeLines(json_content, file.path(jgd_dir, "discovery.json"))
  testthat::local_mocked_bindings(
    jgd_cache_dir = function() file.path(cache_dir, "jgd"),
    .package = "jgd",
    .env = envir
  )
  cache_dir
}

# Mock jgd_cache_dir() to return an empty directory (no discovery file).
set_empty_discovery_env = function(envir = parent.frame()) {
  empty_dir = withr::local_tempdir("jgd-empty-", .local_envir = envir)
  testthat::local_mocked_bindings(
    jgd_cache_dir = function() file.path(empty_dir, "jgd"),
    .package = "jgd",
    .env = envir
  )
}

# Snapshot an R value as pretty-printed JSON matching jgd wire format
expect_json_snapshot = function(x) {
  json = jsonlite::toJSON(x, auto_unbox = TRUE, pretty = TRUE)
  expect_snapshot(cat(json))
}
