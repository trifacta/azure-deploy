BEGIN;
SET LOCAL myvars.blobHost = '<storage account>.blob.core.windows.net';
SET LOCAL myvars.container = '<container>';

-- datasources
UPDATE datasources
SET
  "blobHost" = current_setting('myvars.blobHost'),
  "container" = current_setting('myvars.container'),
  type = 'wasb'
WHERE type = 'hdfs'
;

-- scriptresults
UPDATE scriptresults
SET
  path = regexp_replace(
    path,
    '(wasb|hdfs):/(/?)[^/]*(/[^"]+)',
    'wasb://' || current_setting('myvars.blobHost') || '/' || current_setting('myvars.container') || E'\\3',
    'g'
  )
WHERE
  path !~ 'wasb://[^@/]+@'
;

-- samples wranglescripts
UPDATE wranglescripts
SET
  transforms = convert_to(
    regexp_replace(
      convert_from(transforms, 'UTF-8'),
      '(wasb|hdfs):/(/?)[^/]*(/[^"]+)',
      'wasb://' || current_setting('myvars.blobHost') || '/' || current_setting('myvars.container') || E'\\3',
      'g'
    ),
    'UTF-8'
  )
FROM
  samples
WHERE
  wranglescripts.id = samples."readscriptId"
;

-- writesettings
UPDATE writeSettings
SET
  path = regexp_replace(
    path,
    '(wasb|hdfs):/(/?)[^/]*(/[^"]+)',
    'wasb://' || current_setting('myvars.blobHost') || '/' || current_setting('myvars.container') || E'\\3',
    'g'
  )
WHERE
  path !~ 'wasb://[^@/]+@'
;

COMMIT;
