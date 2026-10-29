const express = require("express");
const { Pool } = require("pg");
const Redis = require("ioredis");

const app = express();

const PORT = parseInt(process.env.PORT || "3000", 10);
const DB_HOST = process.env.DB_HOST || "postgres";
const DB_PORT = parseInt(process.env.DB_PORT || "5432", 10);
const DB_USER = process.env.DB_USER || "postgres";
const DB_PASSWORD = process.env.DB_PASSWORD || "postgres";
const DB_NAME = process.env.DB_NAME || "postgres";

const REDIS_HOST = process.env.REDIS_HOST || "redis";
const REDIS_PORT = parseInt(process.env.REDIS_PORT || "6379", 10);

const pool = new Pool({
  host: DB_HOST,
  user: DB_USER,
  password: DB_PASSWORD,
  database: DB_NAME,
  port: DB_PORT,
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on("error", (err) => {
  console.error("Unexpected error on idle PostgreSQL client:", err.message);
});

const redis = new Redis({
  host: REDIS_HOST,
  port: REDIS_PORT,
  connectTimeout: 5000,
  maxRetriesPerRequest: 3,
  retryStrategy(times) {
    const delay = Math.min(times * 100, 3000);
    return delay;
  },
});

redis.on("error", (err) => {
  console.error("Redis connection error:", err.message);
});

app.get("/api/users", async (req, res) => {
  let db;
  try {
    db = await pool.connect();
    const result = await db.query("SELECT NOW()");
    db.release();
    db = null;

    try {
      await redis.set("last_call", Date.now());
    } catch (redisErr) {
      console.warn("Warning: Failed to update last_call in Redis:", redisErr.message);
    }

    res.json({ ok: true, time: result.rows[0] });
  } catch (err) {
    console.error("Error handling /api/users:", err.message);
    res.status(500).json({ ok: false, error: err.message });
  } finally {
    if (db) {
      try {
        db.release();
      } catch (releaseErr) {
        console.error("Error releasing database client:", releaseErr.message);
      }
    }
  }
});

app.get("/status", (req, res) => {
  res.json({ status: "ok" });
});

const server = app.listen(PORT, () => {
  console.log(`API running on ${PORT}`);
});

const shutdown = (signal) => {
  console.log(`Received ${signal}, starting graceful shutdown...`);
  server.close(async () => {
    try {
      await pool.end();
      await redis.quit();
      console.log("Cleaned up database and redis connections. Shutdown complete.");
      process.exit(0);
    } catch (err) {
      console.error("Error during graceful shutdown:", err.message);
      process.exit(1);
    }
  });

  setTimeout(() => {
    console.error("Graceful shutdown timeout exceeded. Forcefully exiting.");
    process.exit(1);
  }, 10000).unref();
};

process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));
