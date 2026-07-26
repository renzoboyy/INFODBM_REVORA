require('dotenv').config();
const sql = require('mssql');

const config = {
  server: process.env.DB_SERVER,
  port: Number(process.env.DB_PORT),
  database: process.env.DB_DATABASE,
  user: process.env.DB_USER,
  password: process.env.DB_PASS,
  options: {
    encrypt: false,
    trustServerCertificate: true
  }
};

const poolPromise = new sql.ConnectionPool(config)
  .connect()
  .then(pool => {
    console.log('Connected to', process.env.DB_DATABASE);
    return pool;
  })
  .catch(err => {
    console.error('Database connection failed:', err.message);
    throw err;
  });

module.exports = { sql, poolPromise };
