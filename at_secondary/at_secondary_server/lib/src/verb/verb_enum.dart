enum VerbEnum {
  cram,
  delete,
  from,
  llookup,
  lookup,
  pkam,
  plookup,
  pol,
  scan,
  sync,
  update,
  stats,
  config,
  notify,
  monitor,
  stream,
  batch,
  Index,
  search
}

String getName(VerbEnum d) => '$d'.split('.').last;
