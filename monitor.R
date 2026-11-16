#!/usr/bin/env Rscript
# DNT Cabin Availability Monitor — Fuglemyrhytta (cabin 101209)
# Polls the DNT booking API for 1-night availability and emails
# when a previously-booked date becomes available.
#
# Required environment variables:
#   SMTP_HOST   e.g. smtp.office365.com
#   SMTP_PORT   e.g. 587 (STARTTLS) or 465 (SSL)
#   SMTP_USER   your email / SMTP username
#   SMTP_PASS   your email password or app password
#   EMAIL_FROM  sender address (usually same as SMTP_USER)
#   EMAIL_TO    recipient address for notifications

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})

# ---- Configuration ----------------------------------------------------------

CABIN_ID   <- "101209"
CABIN_NAME <- "Fuglemyrhytta"
CABIN_URL  <- "https://hyttebestilling.dnt.no/hytte/101209"
API_URL    <- "https://hyttebestilling.dnt.no/api/booking/available-price"

GUESTS     <- 1
END_DATE   <- as.Date("2026-12-31")
POLL_DELAY <- 0.2          # seconds between API calls

STATE_FILE <- "state.json"

# Norwegian month and weekday names for email formatting
no_months <- c(
  "januar", "februar", "mars", "april", "mai", "juni",
  "juli", "august", "september", "oktober", "november", "desember"
)
no_weekdays <- c(
  "søndag", "mandag", "tirsdag", "onsdag", "torsdag",
  "fredag", "lørdag"
)

# ---- Helpers ----------------------------------------------------------------

format_no_date <- function(d) {
  wd <- no_weekdays[as.integer(format(d, "%w")) + 1]      # %w: 0=Sunday
  day <- as.integer(format(d, "%d"))
  mo <- no_months[as.integer(format(d, "%m"))]
  yr <- format(d, "%Y")
  sprintf("%s %d. %s %s", wd, day, mo, yr)
}

# Check a single night (arrival = date, departure = date + 1)
check_night <- function(arrival) {
  departure <- arrival + 1
  url <- sprintf(
    "%s?cabinId=%s&fromDate=%s&toDate=%s&numberOfGuests=%d",
    API_URL, CABIN_ID,
    format(arrival, "%Y-%m-%d"),
    format(departure, "%Y-%m-%d"),
    GUESTS
  )
  tryCatch({
    resp <- request(url) |>
      req_headers("User-Agent" = "Mozilla/5.0 (compatible; DNT-Monitor/1.0)") |>
      req_timeout(15) |>
      req_perform()

    body <- resp_body_string(resp) |> fromJSON(flatten = FALSE)

    # API returns {"data": {...}} on success, {"error": {...}} on failure
    if (is.null(body$data)) {
      return(0L)  # error response → treat as unavailable
    }

    # fromJSON converts productsAndPrices array to a data.frame (1 row)
    as.integer(body$data$productsAndPrices$available)
  }, error = function(e) {
    message(sprintf("  [WARN] Failed to check %s: %s",
                    format(arrival, "%Y-%m-%d"), conditionMessage(e)))
    NA_integer_  # network/parse error → unknown, don't treat as booked
  })
}

# ---- Email sending via curl SMTP -------------------------------------------

send_notification_email <- function(new_dates) {
  host <- Sys.getenv("SMTP_HOST")
  port <- Sys.getenv("SMTP_PORT")
  user <- Sys.getenv("SMTP_USER")
  pass <- Sys.getenv("SMTP_PASS")
  from <- Sys.getenv("EMAIL_FROM")
  to   <- Sys.getenv("EMAIL_TO")

  if (host == "" || to == "") {
    cat("[WARN] SMTP credentials not set — skipping email.\n")
    return(invisible())
  }

  # Build email body
  date_lines <- sapply(new_dates, function(d) {
    dt <- as.Date(d)
    sprintf("  - %s", format_no_date(dt))
  })
  body <- paste0(
    sprintf("%d ny(e) ledig(e) dato(er) for %s!\n\n", length(new_dates), CABIN_NAME),
    paste(date_lines, collapse = "\n"),
    "\n\nBestill her: ", CABIN_URL, "\n\n",
    "--\n",
    "Denne meldingen sendes automatisk hver 15. minutt ",
    "naar nye datoer blir tilgjengelige."
  )

  subject <- sprintf("%s — %d ny(e) ledig(e) dato(er)!",
                     CABIN_NAME, length(new_dates))

  # Build raw email (RFC 5322 format)
  email_content <- paste0(
    "From: ", from, "\r\n",
    "To: ", to, "\r\n",
    "Subject: ", subject, "\r\n",
    "Content-Type: text/plain; charset=UTF-8\r\n",
    "\r\n",
    body
  )

  # Write to temp file for curl to read
  email_file <- tempfile(fileext = ".eml")
  writeLines(email_content, email_file)

  # Build curl SMTP URL
  # Port 587 → STARTTLS (smtp://), port 465 → implicit SSL (smtps://)
  if (port == "465") {
    smtp_url <- sprintf("smtps://%s:%s", host, port)
  } else {
    smtp_url <- sprintf("smtp://%s:%s", host, port)
  }

  # Build curl command
  curl_cmd <- sprintf(
    'curl --ssl-reqd --url "%s" --mail-from "%s" --mail-rcpt "%s" --user "%s:%s" --upload-file "%s" --silent --show-error',
    smtp_url, from, to, user, pass, email_file
  )

  cat(sprintf("[EMAIL] Sending notification to %s (%d new opening(s))...\n",
              to, length(new_dates)))

  result <- tryCatch({
    output <- system2("curl", args = c(
      "--ssl-reqd",
      "--url", smtp_url,
      "--mail-from", from,
      "--mail-rcpt", to,
      "--user", paste0(user, ":", pass),
      "--upload-file", email_file,
      "--silent", "--show-error"
    ), stderr = TRUE, stdout = TRUE)

    status <- attr(output, "status")
    if (is.null(status) || status == 0) {
      cat(sprintf("[EMAIL] Sent successfully to %s\n", to))
      TRUE
    } else {
      cat(sprintf("[ERROR] curl SMTP failed (exit %d): %s\n",
                  status, paste(output, collapse = "\n")))
      FALSE
    }
  }, error = function(e) {
    cat(sprintf("[ERROR] Failed to send email: %s\n", conditionMessage(e)))
    FALSE
  })

  unlink(email_file)
  invisible(result)
}

# ---- Main -------------------------------------------------------------------

main <- function() {
  # Test mode: send a fake email to verify SMTP works, then exit
  test_mode <- Sys.getenv("TEST_EMAIL") == "true"
  if (test_mode) {
    cat("[TEST MODE] Sending a test email to verify SMTP settings...\n")
    fake_dates <- format(Sys.Date() + 7, "%Y-%m-%d")
    send_notification_email(fake_dates)
    cat("\nDone (test mode).\n")
    return(invisible())
  }

  today <- Sys.Date()
  dates <- seq(today, END_DATE, by = "day")
  cat(sprintf("[%s] Checking %d nights from %s to %s\n",
              format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
              length(dates),
              format(dates[1], "%Y-%m-%d"),
              format(dates[length(dates)], "%Y-%m-%d")))

  # Poll each night
  available_now <- list()
  for (i in seq_along(dates)) {
    d <- dates[i]
    avail <- check_night(d)
    if (!is.na(avail) && avail > 0) {
      available_now[[format(d, "%Y-%m-%d")]] <- avail
      cat(sprintf("  [LEDIG] %s (available: %d)\n",
                  format(d, "%Y-%m-%d"), avail))
    }
    if (i < length(dates)) Sys.sleep(POLL_DELAY)
  }

  available_dates <- names(available_now)
  cat(sprintf("\nTotal available nights: %d\n", length(available_dates)))

  # Load previous state
  prev_dates <- character(0)
  if (file.exists(STATE_FILE)) {
    state <- tryCatch(fromJSON(STATE_FILE), error = function(e) NULL)
    if (!is.null(state) && !is.null(state$available_dates)) {
      # fromJSON may return an empty list for [] — coerce to character
      prev_dates <- as.character(state$available_dates)
    }
  }

  # Diff: dates that are available now but weren't before
  new_openings <- setdiff(available_dates, prev_dates)
  cat(sprintf("New openings since last check: %d\n", length(new_openings)))

  # Save updated state (always — so we also capture dates that got booked)
  new_state <- list(
    cabin_id      = CABIN_ID,
    cabin_name    = CABIN_NAME,
    last_check    = format(Sys.time(), "%Y-%m-%dT%H:%M:%S%z"),
    available_dates = available_dates
  )
  writeLines(toJSON(new_state, auto_unbox = TRUE, pretty = TRUE), STATE_FILE)
  cat(sprintf("State saved to %s\n", STATE_FILE))

  # Send email if there are new openings
  if (length(new_openings) > 0) {
    send_notification_email(new_openings)
  } else {
    cat("No new openings — no email sent.\n")
  }

  cat("\nDone.\n")
}

# Run
main()
