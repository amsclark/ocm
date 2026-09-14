-- Remove the RSS feed reader.
--
-- The home page used to render entries fetched from third party feeds, which
-- an administrator subscribed to on system-feeds.php. The feature is gone:
-- the page, the pikaRssFeed library, the outbound services/cal-rss.php feed
-- and the per-user feed interval preference have all been removed.
--
-- Feed subscriptions are configuration, not case data, and nothing in this
-- application reads the table any more. It is dropped so an upgraded install
-- does not keep a table of third party URLs, their cached bodies and a
-- counter row for them.
--
-- The counters row goes with it. The `counters` table hands out ids, so a row
-- naming a table that no longer exists is only clutter. The DELETE is written
-- against the name, not a row number, and is safe to re-apply: the entrypoint
-- runs every file in APPLY_IN_ORDER on every boot.

DROP TABLE IF EXISTS `rss_feeds`;

DELETE FROM `counters` WHERE `id` = 'rss_feeds';
