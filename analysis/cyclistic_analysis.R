############################################################
# Cyclistic bike-share analysis
# Google Data Analytics Certificate capstone case study
#
# Question: how do annual members and casual riders use
# Cyclistic bikes differently?
#
# Data: Divvy (Chicago) public trip data, Q1 2019 and Q1 2020,
# https://divvy-tripdata.s3.amazonaws.com/index.html
# (license: https://divvybikes.com/data-license-agreement)
#
# Run from the repository root:  Rscript analysis/cyclistic_analysis.R
# Writes tables to outputs/ and charts to outputs/charts/.
############################################################

suppressPackageStartupMessages({
  library(dplyr)
  library(ggplot2)
})

data_dir   <- "data"
out_dir    <- "outputs"
chart_dir  <- file.path(out_dir, "charts")
dir.create(data_dir,  showWarnings = FALSE)
dir.create(chart_dir, showWarnings = FALSE, recursive = TRUE)

# ---- 1. Get the data ---------------------------------------------------------
base_url <- "https://divvy-tripdata.s3.amazonaws.com/"
files    <- c(q1_2019 = "Divvy_Trips_2019_Q1", q1_2020 = "Divvy_Trips_2020_Q1")

for (f in files) {
  zip_path <- file.path(data_dir, paste0(f, ".zip"))
  if (!file.exists(zip_path)) {
    download.file(paste0(base_url, f, ".zip"), zip_path, mode = "wb")
  }
}

read_zip_csv <- function(f) {
  zip_path <- file.path(data_dir, paste0(f, ".zip"))
  read.csv(unz(zip_path, paste0(f, ".csv")), stringsAsFactors = FALSE)
}

q1_2019 <- read_zip_csv(files[["q1_2019"]])
q1_2020 <- read_zip_csv(files[["q1_2020"]])

# ---- 2. Put both quarters on one schema -------------------------------------
# 2019 uses older column names and "Subscriber"/"Customer"; 2020 uses
# "member"/"casual". Rename 2019 to the 2020 schema and keep shared columns.
q1_2019 <- q1_2019 %>%
  transmute(
    ride_id            = as.character(trip_id),
    started_at         = start_time,
    ended_at           = end_time,
    start_station_id   = from_station_id,
    start_station_name = from_station_name,
    end_station_id     = to_station_id,
    end_station_name   = to_station_name,
    member_casual      = recode(usertype, Subscriber = "member", Customer = "casual")
  )

q1_2020 <- q1_2020 %>%
  transmute(
    ride_id, started_at, ended_at,
    start_station_id, start_station_name,
    end_station_id, end_station_name,
    member_casual
  )

all_trips <- bind_rows(q1_2019, q1_2020)
rows_raw  <- nrow(all_trips)

# ---- 3. Derive fields and clean ---------------------------------------------
# Times are local Chicago time; parsing in that zone keeps durations correct
# across the March daylight-saving change.
all_trips <- all_trips %>%
  mutate(
    started_at  = as.POSIXct(started_at, format = "%Y-%m-%d %H:%M:%S", tz = "America/Chicago"),
    ended_at    = as.POSIXct(ended_at,   format = "%Y-%m-%d %H:%M:%S", tz = "America/Chicago"),
    ride_length = as.numeric(difftime(ended_at, started_at, units = "mins")),
    year        = as.integer(format(started_at, "%Y")),
    day_of_week = factor(weekdays(started_at),
                         levels = c("Monday", "Tuesday", "Wednesday", "Thursday",
                                    "Friday", "Saturday", "Sunday")),
    hour        = as.integer(format(started_at, "%H")),
    weekend     = day_of_week %in% c("Saturday", "Sunday")
  )

# Remove: rides that start at "HQ QR" (bikes taken out of service for
# quality checks), rides with zero or negative length, and unparseable rows.
cleaning_log <- tibble::tibble(
  step = c("Raw rows (Q1 2019 + Q1 2020)",
           "Removed: start station HQ QR",
           "Removed: ride length zero or negative",
           "Removed: missing timestamps or user type"),
  rows = c(rows_raw,
           sum(all_trips$start_station_name == "HQ QR", na.rm = TRUE),
           sum(all_trips$start_station_name != "HQ QR" & all_trips$ride_length <= 0, na.rm = TRUE),
           sum(is.na(all_trips$ride_length) | !all_trips$member_casual %in% c("member", "casual")))
)

trips <- all_trips %>%
  filter(!is.na(ride_length),
         member_casual %in% c("member", "casual"),
         start_station_name != "HQ QR",
         ride_length > 0)

cleaning_log <- bind_rows(cleaning_log,
                          tibble::tibble(step = "Rows analysed", rows = nrow(trips)))
write.csv(cleaning_log, file.path(out_dir, "cleaning_log.csv"), row.names = FALSE)

# ---- 4. Summaries ------------------------------------------------------------
by_type <- trips %>%
  group_by(member_casual) %>%
  summarise(
    rides              = n(),
    share_of_rides     = n() / nrow(trips),
    mean_ride_min      = mean(ride_length),
    median_ride_min    = median(ride_length),
    total_ride_hours   = sum(ride_length) / 60,
    weekend_share      = mean(weekend),
    .groups = "drop"
  ) %>%
  mutate(share_of_ride_time = total_ride_hours / sum(total_ride_hours))

by_type_year <- trips %>%
  count(year, member_casual, name = "rides")

by_weekday <- trips %>%
  group_by(member_casual, day_of_week) %>%
  summarise(rides = n(),
            mean_ride_min   = mean(ride_length),
            median_ride_min = median(ride_length),
            .groups = "drop")

by_hour <- trips %>%
  filter(!weekend) %>%
  count(member_casual, hour, name = "rides") %>%
  group_by(member_casual) %>%
  mutate(share_of_weekday_rides = rides / sum(rides)) %>%
  ungroup()

top_casual_stations <- trips %>%
  filter(member_casual == "casual") %>%
  count(start_station_name, name = "casual_rides", sort = TRUE) %>%
  slice_head(n = 10)

write.csv(by_type,             file.path(out_dir, "summary_by_user_type.csv"), row.names = FALSE)
write.csv(by_type_year,        file.path(out_dir, "rides_by_year_and_user_type.csv"), row.names = FALSE)
write.csv(by_weekday,          file.path(out_dir, "summary_by_weekday.csv"), row.names = FALSE)
write.csv(by_hour,             file.path(out_dir, "weekday_rides_by_hour.csv"), row.names = FALSE)
write.csv(top_casual_stations, file.path(out_dir, "top_casual_start_stations.csv"), row.names = FALSE)

# ---- 5. Charts ---------------------------------------------------------------
# Members listed first in every legend
by_weekday$member_casual <- factor(by_weekday$member_casual, levels = c("member", "casual"))
by_hour$member_casual    <- factor(by_hour$member_casual,    levels = c("member", "casual"))
type_colors <- c(member = "#2a78d6", casual = "#eb6834")
type_labels <- c(member = "Annual members", casual = "Casual riders")

theme_cyc <- theme_minimal(base_size = 12) +
  theme(panel.grid.minor = element_blank(),
        panel.grid.major.x = element_blank(),
        panel.grid.major.y = element_line(color = "#e6e6e3", linewidth = 0.3),
        legend.position = "top", legend.title = element_blank(),
        plot.title = element_text(face = "bold"),
        plot.subtitle = element_text(color = "#52514e"),
        plot.caption = element_text(color = "#52514e", size = 8, hjust = 0))
caption <- "Source: Divvy trip data, Q1 2019 and Q1 2020. Rides from HQ QR and rides of zero or negative length removed."

save_chart <- function(p, name, w = 8, h = 4.5) {
  ggsave(file.path(chart_dir, name), p, width = w, height = h, dpi = 150, bg = "white")
}

p1 <- ggplot(by_weekday, aes(day_of_week, rides, fill = member_casual)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.72) +
  scale_fill_manual(values = type_colors, labels = type_labels) +
  scale_y_continuous(labels = scales::comma) +
  labs(title = "Members ride far more often, and mostly on weekdays",
       subtitle = "Number of rides by day of week", x = NULL, y = "Rides", caption = caption) +
  theme_cyc
save_chart(p1, "rides_by_weekday.png")

p2 <- ggplot(by_weekday, aes(day_of_week, median_ride_min, fill = member_casual)) +
  geom_col(position = position_dodge(width = 0.8), width = 0.72) +
  scale_fill_manual(values = type_colors, labels = type_labels) +
  labs(title = "Casual riders take longer rides every day of the week",
       subtitle = "Median ride length (minutes) by day of week", x = NULL, y = "Minutes", caption = caption) +
  theme_cyc
save_chart(p2, "median_ride_length_by_weekday.png")

p3 <- ggplot(by_hour, aes(hour, share_of_weekday_rides, color = member_casual)) +
  geom_line(linewidth = 0.9) +
  geom_point(size = 1.6) +
  scale_color_manual(values = type_colors, labels = type_labels) +
  scale_x_continuous(breaks = seq(0, 23, 3), labels = function(h) sprintf("%02d:00", h)) +
  scale_y_continuous(labels = scales::percent) +
  labs(title = "Member weekday rides peak at commute hours",
       subtitle = "Share of each group's weekday rides, by start hour", x = "Start hour", y = NULL, caption = caption) +
  theme_cyc
save_chart(p3, "weekday_rides_by_hour.png")

p4 <- ggplot(top_casual_stations,
             aes(casual_rides, reorder(start_station_name, casual_rides))) +
  geom_col(fill = type_colors[["casual"]], width = 0.7) +
  geom_text(aes(label = scales::comma(casual_rides)), hjust = -0.15, size = 3.2, color = "#0b0b0b") +
  scale_x_continuous(labels = scales::comma, expand = expansion(mult = c(0, 0.12))) +
  labs(title = "Where casual riders start",
       subtitle = "Top 10 start stations by casual rides", x = "Casual rides", y = NULL, caption = caption) +
  theme_cyc + theme(panel.grid.major.y = element_blank(),
                    panel.grid.major.x = element_line(color = "#e6e6e3", linewidth = 0.3))
save_chart(p4, "top_casual_start_stations.png")

# ---- 6. Console summary ------------------------------------------------------
print(cleaning_log)
print(by_type, width = Inf)
