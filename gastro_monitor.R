#!/usr/bin/env Rscript
# Le Benjamin Booking Monitor — booking.gastroplanner.no/lebenjamin/t
# Single-check version: the GitHub Actions workflow calls this script
# once per cycle inside a 15-minute polling loop.
#
# Watches availability for a table of GUESTS people on TARGET_DATE and
# sends an email the moment it becomes bookable.
#
# Required environment variables (same secrets as the DNT monitor):
#   SMTP_HOST   e.g. smtp.gmail.com
#   SMTP_PORT   e.g. 587
#   SMTP_USER   your Gmail address
#   SMTP_PASS   your Gmail app password
#   EMAIL_FROM  sender address (same as SMTP_USER)
#   EMAIL_TO    recipient address for notifications
#
# Optional:
#   TEST_EMAIL=true   send a test email and skip the availability check

suppressPackageStartupMessages({
  library(httr2)
  library(jsonlite)
})

# ---- Configuration ----------------------------------------------------------

API_BASE     <- "https://booking.gastroplanner.no/api/widget"
RESTAURANT   <- "lebenjamin"          # window.restaurant on the booking page
WIDGET       <- "t"                   # window.widget on the booking page
PLACE_NAME   <- "Le Benjamin Bar & Bistro"
BOOKING_URL  <- "https://booking.gastroplanner.no/lebenjamin/t"

GUESTS       <- 4
TARGET_DATE  <- as.Date("2026-12-12") # the date you want a table for
TARGET_MONTH <- format(TARGET_DATE, "%Y-%m")

STATE_FILE <- "gastro_state.json"

# Norwegian month and weekday names for email formatting
no_months <- c(
  "januar", "februar", "mars", "april", "mai", "juni",
  "juli", "august", "september", "oktober", "november", "desember"
)
no_weekdays <- c(
  "søndag", "mandag", "tirsdag", "onsdag", "torsdag",
  "fredag", "lørdag"
)

format_no_date <- function(d) {
  wd <- no_weekdays[as.integer(format(d, "%w")) + 1]      # %w: 0=Sunday
  day <- as.integer(format(d, "%d"))
  mo <- no_months[as.integer(format(d, "%m"))]
  yr <- format(d, "%Y")
  sprintf("%s %d. %s %s", wd, day, mo, yr)
}

# ---- Availability check -----------------------------------------------------
# One API call returns the whole month's status for the given party size.
# status == 1 → bookable, status == 0 → not available.

check_month <- function(month, guests) {
  url <- sprintf(
    "%s/bookings/availability/month?month=%s&guests=%d",
    API_BASE, month, guests
  )
  tryCatch({
    resp <- request(url) |>
      req_headers(
        "Restaurant" = RESTAURANT,
        "Widget"     = WIDGET,
        "Accept"     = "application/json",
        "User-Agent" = "Mozilla/5.0 (compatible; BookingMonitor/1.0)"
      ) |>
      req_timeout(15) |>
      req_perform()

    body <- resp_body_string(resp) |> fromJSON(flatten = FALSE)

    if (is.null(body$result)) {
      message("[WARN] Unexpected API response.")
      return(NULL)
    }

    # result is a data.frame with columns: date, status, notes, status_code
    body$result
  }, error = function(e) {
    message(sprintf("[WARN] Failed to check availability: %s",
                    conditionMessage(e)))
    NULL
  })
}

# ---- Email sending via curl SMTP (same as DNT monitor) ----------------------

send_notification_email <- function(subject, body) {
  host <- Sys.getenv("SMTP_HOST")
  port <- Sys.getenv("SMTP_PORT")
  user <- Sys.getenv("SMTP_USER")
  pass <- Sys.getenv("SMTP_PASS")
  from <- Sys.getenv("EMAIL_FROM")
  to   <- Sys.getenv("EMAIL_TO")

  if (host == "" || to == "") {
    cat("[WARN] SMTP credentials not set — skipping email.\n")
    return(invisible(FALSE))
  }

  email_content <- paste0(
    "From: ", from, "\r\n",
    "To: ", to, "\r\n",
    "Subject: ", subject, "\r\n",
    "Content-Type: text/plain; charset=UTF-8\r\n",
    "\r\n",
    body
  )

  email_file <- tempfile(fileext = ".eml")
  writeLines(email_content, email_file)

  if (port == "465") {
    smtp_url <- sprintf("smtps://%s:%s", host, port)
  } else {
    smtp_url <- sprintf("smtp://%s:%s", host, port)
  }

  cat(sprintf("[EMAIL] Sending notification to %s...\n", to))

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
  if (Sys.getenv("TEST_EMAIL") == "true") {
    cat("[TEST MODE] Sending a test email to verify SMTP settings...\n")
    subject <- sprintf("%s — TESTmelding", PLACE_NAME)
    body <- paste0(
      "Dette er en testmelding fra overvåkningen av ",
      PLACE_NAME, ".\n\n",
      "Hvis du leser denne, fungerer e-postutsendelsen.\n\n",
      "Overvåker: bord for ", GUESTS, " personer ",
      format_no_date(TARGET_DATE), "\n",
      "Bestill her: ", BOOKING_URL, "\n"
    )
    send_notification_email(subject, body)
    cat("\nDone (test mode).\n")
    return(invisible())
  }

  cat(sprintf("[%s] Checking %s for a table for %d on %s\n",
              format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
              PLACE_NAME, GUESTS, TARGET_DATE))

  # Load previous state FIRST
  prev_available <- FALSE
  first_run <- !file.exists(STATE_FILE)
  if (!first_run) {
    state <- tryCatch(fromJSON(STATE_FILE), error = function(e) NULL)
    if (!is.null(state) && !is.null(state$available)) {
      prev_available <- isTRUE(state$available)
    }
  }

  month_data <- check_month(TARGET_MONTH, GUESTS)

  # If the API call failed, leave state untouched (no false change)
  if (is.null(month_data)) {
    cat("[WARN] No API data — state untouched, no email sent.\n")
    return(invisible())
  }

  available_now <- FALSE
  row <- month_data[month_data$date == format(TARGET_DATE, "%Y-%m-%d"), ]
  if (nrow(row) > 0) {
    available_now <- (row$status == 1)
    cat(sprintf("  Status for %s (guests=%d): %s\n",
                TARGET_DATE, GUESTS,
                if (available_now) "LEDIG — kan bookes!" else "ikke tilgjengelig"))
  } else {
    cat("  [WARN] Target date not in API response.\n")
  }

  # Write state ONLY when availability changed (or first run) so the
  # workflow's git diff check can skip unchanged cycles
  if (first_run || available_now != prev_available) {
    new_state <- list(
      restaurant  = RESTAURANT,
      target_date = format(TARGET_DATE, "%Y-%m-%d"),
      guests      = GUESTS,
      available   = available_now
    )
    writeLines(toJSON(new_state, auto_unbox = TRUE, pretty = TRUE), STATE_FILE)
    cat("Availability changed — state saved.\n")
  } else {
    cat("No change — state file untouched.\n")
  }

  # Send email on transition from not-available to available
  # (also fires on the very first run if the table is already bookable)
  if (available_now && !prev_available) {
    subject <- sprintf("%s — Bord for %d ledig %s!",
                       PLACE_NAME, GUESTS, format_no_date(TARGET_DATE))
    body <- paste0(
      "Et bord for ", GUESTS, " personer er ledig hos ", PLACE_NAME, "!\n\n",
      "Dato: ", format_no_date(TARGET_DATE), "\n\n",
      "Bestill her: ", BOOKING_URL, "\n\n",
      "--\n",
      "Denne meldingen sendes automatisk sa snart bordet blir tilgjengelig."
    )
    send_notification_email(subject, body)
  } else if (available_now && prev_available) {
    cat("Still available since last check — no email sent.\n")
  } else {
    cat("Not available — no email sent.\n")
  }

  cat("\nDone.\n")
}

# Run
main()
