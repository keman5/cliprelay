ALTER TABLE users ADD COLUMN lock_level INTEGER NOT NULL DEFAULT 0;
-- Extend any still-active 15-minute cooldown to four hours from its original start.
UPDATE users SET lock_level = 1, locked_until = locked_until + 13500000
WHERE locked_until > unixepoch() * 1000;
