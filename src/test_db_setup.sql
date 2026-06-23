DROP TABLE IF EXISTS posts CASCADE;

DROP TABLE IF EXISTS users CASCADE;

CREATE TABLE users (
  id SERIAL PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,
  age INTEGER NOT NULL
);

CREATE TABLE posts (
  id SERIAL PRIMARY KEY,
  author_id INTEGER NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  published BOOLEAN NOT NULL,
  tags TEXT [] NOT NULL,
  metadata JSONB NOT NULL
);

CREATE INDEX posts_author_id_idx ON posts (author_id);

--------------------------------------------------------
INSERT INTO
  users (name, age)
VALUES
  ('Alice', 30),
  -- id 1
  ('Bob', 17),
  -- id 2
  ('Frank', 65),
  -- id 3 (no posts)
  ('Grace', 40),
  -- id 4
  ('Heidi', 22);

-- id 5
INSERT INTO
  posts (author_id, title, published, tags, metadata)
VALUES
  (
    1,
    'Alice Post 1',
    TRUE,
    '{"saga","db"}',
    '{"source":"web","featured":true}'
  ),
  (
    1,
    'Alice Post 2',
    TRUE,
    '{"saga"}',
    '{"source":"web","featured":false}'
  ),
  (
    1,
    'Alice Post 3',
    FALSE,
    '{"draft"}',
    '{"source":"cli","featured":false}'
  ),
  (
    1,
    'Alice Post 4',
    TRUE,
    '{"db","query"}',
    '{"source":"web","featured":true}'
  ),
  (
    1,
    'Alice Post 5',
    TRUE,
    '{"saga","query"}',
    '{"source":"api","featured":false}'
  ),
  (
    1,
    'Alice Post 6',
    FALSE,
    '{}',
    '{"source":"web","featured":false}'
  ),
  (
    2,
    'Bob Post 1',
    TRUE,
    '{"intro"}',
    '{"source":"web","featured":true}'
  ),
  (
    4,
    'Grace Post 1',
    FALSE,
    '{"wip"}',
    '{"source":"cli","featured":false}'
  );