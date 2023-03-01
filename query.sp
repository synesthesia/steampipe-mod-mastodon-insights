query "timeline" {
  sql = <<EOQ
    with toots as (
      select
        case when display_name = '' then username else display_name end as person,
        case
          when reblog -> 'url' is null then
            content
          else
            reblog_content
        end as toot,
        to_char(created_at, 'YYYY-MM-DD HH24:MI') as created_at,
        case
          when reblog -> 'url' is not null then '▲'
          else ' '
        end as boosted,
        case
          when in_reply_to_account_id is not null then ' → ' || ( select acct from mastodon_account where id = in_reply_to_account_id )
          else ''
        end as in_reply_to,
        case
          when reblog -> 'url' is not null then instance_qualified_reblog_url
          else instance_qualified_url
        end as url,
        case
          when reblog is not null then reblog ->> 'reblogs_count'
          else ''
        end as reblog_count,
        case
          when reblog is not null then reblog ->> 'favourites_count'
          else ''
        end as fave_count,
        reblog
      from
        mastodon_toot
      where
        timeline = $1
        and url !~ '${local.timeline_exclude}'
      limit $2
    ),
    boosted as (
      select
        created_at,
        $3 as boost,
        boosted,
        in_reply_to,
        person,
        toot,
        reblog_count,
        fave_count,
        url,
        reblog
      from
        toots
      order by
        created_at desc
    )
    select
      created_at,
      person ||
        case
          when in_reply_to is null then ''
          else in_reply_to
        end as person,
      case
        when reblog is not null then boosted || ' ' || toot || ' ★ ' || fave_count || ' ▲ ' || reblog_count
        else boosted || ' ' || toot
      end as toot,
      url
    from
      boosted
    where
      boost = boosted
      or boost = 'include'
      or boost = 'n/a'
  EOQ
  param "timeline" {}
  param "limit" {}
  param "boost" {}
}

query "search_status" {
  sql = <<EOQ
    with toots as (
      select
        account_url as account,
        case when display_name = '' then username else display_name end as person,
        case
          when reblog -> 'url' is null then
            content
          else
            reblog_content
        end as toot,
        to_char(created_at, 'MM-DD HH24:MI') as created_at,
        case
          when reblog -> 'url' is not null then '▲'
          else ''
        end as boosted,
        case
          when in_reply_to_account_id is not null then ' → ' || ( select acct from mastodon_account where id = in_reply_to_account_id )
          else ''
        end as in_reply_to,
        case
          when reblog -> 'url' is not null then reblog ->> 'url'
          else url
        end as url
      from
        mastodon_toot
      where
        timeline = 'search_status'
        and query = $1
      limit ${local.limit}
    )
    select
      account,
      person ||
        case
          when in_reply_to is null then ''
          else in_reply_to
        end as person,
      boosted || ' ' || substring(toot from 1 for 200) as toot,
      url
    from
      toots
    order by
      created_at desc
  EOQ
  param "search_term" {}
}

query "favorite" {
  sql = <<EOQ
    with toots as (
      select
        case when display_name = '' then username else display_name end as person,
        case
          when reblog -> 'url' is null then
            content
          else
            reblog_content
        end as toot,
        to_char(created_at, 'YYYY-MM-DD HH24:MI') as created_at,
        case
          when reblog -> 'url' is not null then '▲'
          else ''
        end as boosted,
        case
          when in_reply_to_account_id is not null then ' → ' || ( select acct from mastodon_account where id = in_reply_to_account_id )
          else ''
        end as in_reply_to,
        instance_qualified_url
      from
        mastodon_favorite
      limit $1
    )
    select
      created_at,
      person ||
        case
          when in_reply_to is null then ''
          else in_reply_to
        end as person,
      boosted || ' ' || substring(toot from 1 for 200) as toot,
      instance_qualified_url
    from
      toots
    order by
      created_at desc
    limit $1
  EOQ
  param "limit" {}
}

/*
The duplicate code in the above three queries could be DRYed out using a Postgres function parameterized by table name. But there's
not currently a standard way to deploy a mod that defines and uses functions. If we could alternatively parameterize queries by
table name in HCL that would be very nice.
*/

query "search_hashtag" {
  sql = <<EOQ
    with data as (
      select
        name,
        url || '.rss' as feed_link
      from
        mastodon_search_hashtag
      where
        query = $1
        and name = query
      limit 1
    )
    select
      to_char(r.published, 'YYYY-MM-DD') as published,
      d.name as tag,
      (
        select string_agg(trim(JsonString::text, '"'), ', ')
        from jsonb_array_elements(r.categories) JsonString
      ) as categories,
      r.guid as link,
      ( select content as toot from mastodon_toot where timeline = 'search_status' and query = r.guid ) as content
    from
      data d
    join
      rss_item r
    on
      r.feed_link = d.feed_link
    order by
      r.published desc
    limit 10
    EOQ
}

query "search_people" {
  sql = <<EOQ
    with data as (
      select
        id,
        instance_qualified_account_url,
        case when display_name = '' then username else display_name end as person,
        to_char(created_at, 'YYYY-MM-DD') as created_at,
        followers_count,
        following_count,
        statuses_count as toots,
        note
      from
        mastodon_search_account
      where
        query = $1
      order by
        person
    )
    select
      d.instance_qualified_account_url,
      d.person,
      case when r.following then '✔️' else '' end as i_follow,
      case when r.followed_by then '✔️' else '' end as follows_me,
      d.created_at,
      d.followers_count as followers,
      d.following_count as following,
      d.toots,
      d.note
    from
      data d
    join
      mastodon_relationship r
    on
      d.id = r.id
  EOQ
  param "search_term" {}
}

query "followers" {
  sql = <<EOQ
    with data as (
      select
        l.title as list,
        a.*
      from
        mastodon_list l
      join
        mastodon_list_account a
      on
        l.id = a.list_id
    ),
    combined as (
      select
        d.list,
        f.instance_qualified_account_url,
        case when f.display_name = '' then f.username else f.display_name end as person,
        to_char(f.created_at, 'YYYY-MM-DD') as since,
        f.followers_count as followers,
        f.following_count as following,
        (CASE WHEN f.following_count <> 0 THEN TRUNC((f.followers_count::decimal / f.following_count), 2) ELSE null END) as followratio,
        f.statuses_count as toots,
        f.note
      from
        mastodon_followers f
      left join
        data d
      on
        f.id = d.id
    )
    select
      *
    from
      combined
    order by
      person
  EOQ
}

/*
Joining with `mastodon_relationship` is possible, and useful -- I want to see at a glance
if a person I follow has followed me back! -- but not yet practical. The API's `accounts/relationships`
endpoint takes an array of ids, but the `mastodon_relationship` table for now only takes one id at a time because
you can't make an URL like `accounts/relationships?id[]=1&id[]=2...&id[]=500`. The one-at-a-time approach
is not only slow, but worse, quickly exhausts the 300-API-calls-per-5-minutes limit if you are following
hundreds of people.

TBD: Work out a way to query `mastodon_relationship` with batches of (10? 100?) ids.

Meanwhile, see query.search_people, this approach is practical there if the query yields a small result set.
*/
query "following" {
  sql = <<EOQ
    with data as (
      select
        l.title as list,
        a.*
      from
        mastodon_list l
      join
        mastodon_list_account a
      on
        l.id = a.list_id
    ),
    combined as (
      select
        d.list,
        f.instance_qualified_account_url,
        case when f.display_name = '' then f.username else f.display_name end as person,
        to_char(f.created_at, 'YYYY-MM-DD') as since,
        f.followers_count as followers,
        f.following_count as following,
        (CASE WHEN f.following_count <> 0 THEN TRUNC((f.followers_count::decimal / f.following_count), 2) ELSE null END) as followratio,
        f.statuses_count as toots,
        f.note
      from
        mastodon_following f
      left join
        data d
      on
        f.id = d.id
    )
    select
      *
    from
      combined
    order by
      person
  EOQ
}

query "notification" {
  sql = <<EOQ
    with notifications as (
      select
        category,
        instance_qualified_account_url,
        account_id,
        display_name as person,
        to_char(created_at, 'MM-DD HH24:MI') as created_at,
        instance_qualified_status_url,
        status_content
      from
        mastodon_notification
      limit $1
    )
    select
      n.created_at,
      n.category,
      n.person,
      n.instance_qualified_account_url,
      case when r.following then '✔️' else '' end as following,
      case when r.followed_by then '✔️' else '' end as followed_by,
      substring(n.status_content from 1 for 200) as toot,
      case
        when n.instance_qualified_status_url != '' then n.instance_qualified_status_url
        else n.instance_qualified_account_url
      end as url
    from
      notifications n
    join
      mastodon_relationship r
    on
      r.id = n.account_id
    order by
      n.created_at desc
  EOQ
}

query "list" {
  sql = <<EOQ
    with list_ids as (
      select
        id,
        title as list
      from
       mastodon_list
    ),
    data as (
      select
        l.list,
        to_char(t.created_at, 'YYYY-MM-DD') as day,
        case when t.display_name = '' then t.username else t.display_name end as person,
        t.instance_qualified_url as url,
        substring(t.content from 1 for 200) as toot
      from
        mastodon_toot t
      join
        list_ids l
      on
        l.id = t.list_id
      where
        timeline = 'list'
        and l.list = $1
        and t.reblog -> 'url' is null -- only original posts
        and t.in_reply_to_account_id is null -- only original posts
        limit 20
    )
    select distinct on (person, day) -- only one per person per day
      day,
      person,
      toot,
      url
    from
      data
    order by
      day desc, person
  EOQ
  param "title" {}
}

query "list_account" {
  sql = <<EOQ
    select
      l.title as list,
      array_to_string( array_agg( lower(a.username) order by lower(a.username)), ', ') as people
    from
      mastodon_list l
    join
      mastodon_list_account a
    on
      l.id = a.list_id
    group by
      l.title
  EOQ
}

query "list_account_follows" {
  sql = <<EOQ
    with list_account as (
      select
        a.id,
        l.title as list
      from
        mastodon_list l
        join mastodon_list_account a on l.id = a.list_id
    ),
    list_account_follows as (
      select
        list
      from
        mastodon_following
        left join list_account using (id)
    )
    select 'follows listed' as label, count(*) from list_account_follows where list is not null
    union
    select 'follows unlisted' as label, count(*) from list_account_follows where list is null
  EOQ
}

query "my_toots" {
  sql = <<EOQ
    with data as (
      select
        account_url as account,
        to_char(created_at, 'YYYY-MM-DD HH24:MI') as created_at,
        case
          when reblog -> 'url' is not null then '▲'
          else ''
        end as boosted,
        case
          when reblog is null then
            substring(content from 1 for 300) || ' ★ ' || (status->>'favourites_count') || ' ▲ ' || (status->>'reblogs_count')
          else
            substring(reblog_content from 1 for 300) || ' ★ ' || (reblog->>'favourites_count') || ' ▲ ' || (reblog->>'reblogs_count')
        end as toot,
        case
          when in_reply_to_account_id is not null then ' → ' || ( select acct from mastodon_account where id = in_reply_to_account_id )
          else ''
        end as in_reply_to,
        case
          when reblog -> 'url' is not null then instance_qualified_reblog_url
          else instance_qualified_url
        end as instance_qualified_url
      from
        mastodon_toot
      where
        timeline = 'me'
      limit $1
    )
    select
      created_at,
      instance_qualified_url,
      boosted || ' ' || toot as toot
    from
      data
    order by
      created_at desc
  EOQ
  param "limit" {}
}

query "connection" {
  sql = <<EOQ
  select
    _ctx ->> 'connection_name' as connection,
    name as server
  from
    mastodon_server
  EOQ
}