library(scoringutils)
library(covidHubUtils)
library(dplyr)
library(tidyr)
library(lubridate)
library(here)
library(readr)
library(EuroForecastHub)

data_types <- get_hub_config("target_variables")

## only evaluate if the last 4 weeks hae been submitted
restrict_weeks <- 4

## history to keep
histories <- c(10, Inf)

suppressWarnings(dir.create(here::here("evaluation")))

## load forecasts --------------------------------------------------------------
forecasts <- load_forecasts(
  source = "local_hub_repo",
  hub_repo_path = here(),
  hub = "ECDC"
) %>%
  # set forecast date to corresponding submission date
  mutate(forecast_date = ceiling_date(forecast_date, "week", week_start = 2) - 1) %>%
  filter(forecast_date >= "2021-03-08") %>%
  rename(prediction = value)

## load truth data -------------------------------------------------------------
raw_truth <- load_truth(truth_source = "JHU",
                        temporal_resolution = "weekly",
                        hub = "ECDC")
# get anomalies
anomalies <- read_csv(here("data-truth", "anomalies", "anomalies.csv"))
truth <- anti_join(raw_truth, anomalies) %>%
  mutate(model = NULL) %>%
  rename(true_value = value)

# remove forecasts made directly after a data anomaly
forecasts <- forecasts %>%
  mutate(previous_end_date = forecast_date - 2) %>%
  left_join(anomalies %>%
              rename(previous_end_date = target_end_date),
            by = c("target_variable",
                   "location", "location_name",
                   "previous_end_date")) %>%
  filter(is.na(anomaly)) %>%
  select(-anomaly, -previous_end_date)

data <- scoringutils::merge_pred_and_obs(forecasts, truth,
                                         join = "full")

latest_date <- today()
wday(latest_date) <- get_hub_config("forecast_week_day")

message("Scoring all forecasts.")

scores <- score_forecasts(
  forecasts = data,
  quantiles = get_hub_config("forecast_type")$quantiles
)

write_csv(scores, here::here("evaluation", "scores.csv"))

## can modify manually if wanting to re-run past evaluation
re_run <- FALSE
if (re_run) {
  start_date <- as.Date("2021-03-08") + 4 * 7
} else {
  start_date <- latest_date
}
report_dates <- seq(start_date, latest_date, by = "week")

for (chr_report_date in as.character(report_dates)) {
  tables <- list()
  for (history in histories) {
    report_date <- as.Date(chr_report_date)

    use_scores <- scores %>%
      filter(target_end_date > report_date - history * 7)

    str <- paste("Evaluation as of", report_date)
    if (history < Inf) {
      str <- paste(str, "keeping", history, "weeks of history")
    }
    message(paste0(str, "."))

    tables[[as.character(history)]] <- summarise_scores(
      scores = use_scores,
      report_date = report_date,
      restrict_weeks = restrict_weeks
    )
  }

  combined_table <- bind_rows(tables, .id = "weeks_included") %>%
    mutate(weeks_included = recode(weeks_included, `Inf` = "All"))
  eval_filename <-
    here::here("evaluation", "weekly-summary",
	       paste0("evaluation-", report_date, ".csv"))

  write_csv(combined_table, eval_filename)
}

