mod "mastodon" {
}

locals {
  //host = "https://cloud.steampipe.io/org/acme/workspace/jon/dashboard"
  host = "http://localhost:9194"
  server = "mastodon.social"
  limit = 40
  timeline_exclude = "press.coop"
}

