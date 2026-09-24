CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT);
INSERT INTO searchIndex(name, type, path) VALUES
  ('core.emerg', 'Directive', 'index.html#core.emerg'),
  ('core.alert', 'Directive', '<dash_entry_name=core.alert>index.html#core.alert'),
  ('Extra', 'Guide', '_static/extra.html'),
  ('Gone', 'Guide', 'missing.html');
