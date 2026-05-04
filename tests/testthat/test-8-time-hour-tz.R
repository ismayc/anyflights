context("adjust_time_hour_tz")

# A small in-memory airports lookup so these tests don't hit the network.
mock_airports <- function() {
  tibble::tibble(
    faa   = c("PDX", "JFK", "DEN", "HNL", "XYZ"),
    tzone = c(
      "America/Los_Angeles",
      "America/New_York",
      "America/Denver",
      "Pacific/Honolulu",
      NA_character_
    )
  )
}

test_that("force mode preserves wall clock and corrects the instant per origin", {
  # Simulates raw flights data: airport-local wall clock implicitly tagged UTC
  flights <- tibble::tibble(
    origin    = c("PDX", "JFK", "DEN"),
    time_hour = lubridate::make_datetime(2023, 1, 1, c(9, 9, 9), 0, 0)
  )

  out <- anyflights:::adjust_time_hour_tz(
    flights, mock_airports(), action = "force"
  )

  # Output is a tibble with the original columns (no tzone leaking through)
  expect_setequal(colnames(out), c("origin", "time_hour"))
  expect_s3_class(out$time_hour, "POSIXct")

  # Each origin's instant should equal "9am at airport local tz"
  expected <- c(
    PDX = as.numeric(as.POSIXct("2023-01-01 09:00:00", tz = "America/Los_Angeles")),
    JFK = as.numeric(as.POSIXct("2023-01-01 09:00:00", tz = "America/New_York")),
    DEN = as.numeric(as.POSIXct("2023-01-01 09:00:00", tz = "America/Denver"))
  )
  by_origin <- stats::setNames(as.numeric(out$time_hour), out$origin)
  expect_equal(by_origin[names(expected)], expected)
})

test_that("convert mode preserves the instant and recomputes airport-local components", {
  # Simulates raw weather data: true UTC instants of observations and
  # year/month/day/hour columns derived in UTC.
  weather <- tibble::tibble(
    origin    = c("PDX", "JFK", "DEN"),
    year      = 2023L,
    month     = 1L,
    day       = 1L,
    # 09:00 airport-local in each tz, expressed as UTC hour
    hour      = c(17L, 14L, 16L),
    time_hour = ISOdatetime(2023, 1, 1, c(17, 14, 16), 0, 0, tz = "GMT")
  )

  out <- anyflights:::adjust_time_hour_tz(
    weather, mock_airports(), action = "convert"
  )

  expect_setequal(
    colnames(out),
    c("origin", "year", "month", "day", "hour", "time_hour")
  )
  expect_s3_class(out$time_hour, "POSIXct")

  # Underlying instants are preserved (with_tz, not force_tz)
  in_by  <- stats::setNames(as.numeric(weather$time_hour), weather$origin)
  out_by <- stats::setNames(as.numeric(out$time_hour),     out$origin)
  expect_equal(out_by[names(in_by)], in_by)

  # year/month/day/hour are recomputed in airport-local time => 9am everywhere
  expect_equal(out$hour, rep(9L, 3))
  expect_equal(out$year, rep(2023L, 3))
  expect_equal(out$month, rep(1L, 3))
  expect_equal(out$day, rep(1L, 3))
})

test_that("flights and weather time_hour join across multiple time zones (issue #28)", {
  airports <- mock_airports()
  origins  <- c("PDX", "JFK", "DEN", "HNL")

  # Flights data: airport-local 9am scheduled departure
  flights <- tibble::tibble(
    origin    = origins,
    time_hour = lubridate::make_datetime(2023, 1, 1, 9, 0, 0)
  ) %>%
    anyflights:::adjust_time_hour_tz(airports, action = "force")

  # Weather data: UTC observation at the corresponding instant
  utc_hour <- c(PDX = 17L, JFK = 14L, DEN = 16L, HNL = 19L)
  weather <- tibble::tibble(
    origin    = names(utc_hour),
    year      = 2023L, month = 1L, day = 1L,
    hour      = unname(utc_hour),
    time_hour = ISOdatetime(2023, 1, 1, unname(utc_hour), 0, 0, tz = "GMT")
  ) %>%
    anyflights:::adjust_time_hour_tz(airports, action = "convert")

  joined <- dplyr::inner_join(flights, weather, by = c("origin", "time_hour"))
  expect_equal(nrow(joined), length(origins))
  expect_setequal(joined$origin, origins)
})

test_that("NA tzone leaves time_hour unchanged", {
  raw <- tibble::tibble(
    origin    = c("XYZ", "XYZ"),
    time_hour = lubridate::make_datetime(2023, 1, 1, c(9, 10), 0, 0)
  )

  for (action in c("force", "convert")) {
    out <- anyflights:::adjust_time_hour_tz(raw, mock_airports(), action = action)
    expect_equal(as.numeric(out$time_hour), as.numeric(raw$time_hour),
                 info = paste("action =", action))
  }
})

test_that("single-tz input matches nycflights13 convention", {
  # nycflights13 has all origins in one zone; check we replicate that shape.
  flights <- tibble::tibble(
    origin    = c("JFK", "LGA", "EWR"),
    time_hour = lubridate::make_datetime(2023, 6, 15, c(8, 12, 20), 0, 0)
  )
  airports <- tibble::tibble(
    faa   = c("JFK", "LGA", "EWR"),
    tzone = rep("America/New_York", 3)
  )

  out <- anyflights:::adjust_time_hour_tz(flights, airports, action = "force")

  expect_equal(lubridate::tz(out$time_hour), "America/New_York")
  # Wall clock preserved per origin
  expect_equal(lubridate::hour(out$time_hour[out$origin == "JFK"]), 8)
  expect_equal(lubridate::hour(out$time_hour[out$origin == "LGA"]), 12)
  expect_equal(lubridate::hour(out$time_hour[out$origin == "EWR"]), 20)
})

test_that("the bind across mixed tzs preserves underlying instants", {
  # Even though POSIXct can carry only one tz attribute on a column, the
  # *instants* must remain correct after combining groups, so downstream
  # joins on time_hour return the right rows.
  flights <- tibble::tibble(
    origin    = c("PDX", "JFK", "DEN"),
    time_hour = lubridate::make_datetime(2023, 7, 4, c(6, 6, 6), 0, 0)
  )
  out <- anyflights:::adjust_time_hour_tz(flights, mock_airports(), action = "force")

  # Round-trip: shift instants back by airports$tzone and we should recover
  # the original UTC wall clock (6am everywhere).
  recovered <- purrr::map2_dbl(
    out$origin,
    out$time_hour,
    function(o, t) {
      tz <- mock_airports()$tzone[mock_airports()$faa == o]
      as.numeric(lubridate::with_tz(t, tz))
    }
  )
  expect_equal(recovered, as.numeric(out$time_hour))

  # Hour, when read in each origin's local tz, is always 6
  local_hour <- purrr::map2_int(
    out$origin,
    out$time_hour,
    function(o, t) {
      tz <- mock_airports()$tzone[mock_airports()$faa == o]
      as.integer(lubridate::hour(lubridate::with_tz(t, tz)))
    }
  )
  expect_equal(local_hour, rep(6L, 3))
})
