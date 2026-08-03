require('dotenv').config();
const express = require('express');
const cors = require('cors');
const path = require('path');

const searchRoutes = require('./routes/search');
const registrationRoutes = require('./routes/registration');
const adminRoutes = require('./routes/admin');
const lookupRoutes = require('./routes/lookups');
const authRoutes = require('./routes/auth');
const profileRoutes = require('./routes/profile');
const geoRoutes = require('./routes/geo');

const app = express();

app.use(cors());
app.use(express.json());
app.use(express.static(path.join(__dirname, '..', 'public')));

app.use('/api', searchRoutes);
app.use('/api', registrationRoutes);
app.use('/api', adminRoutes);
app.use('/api', lookupRoutes);
app.use('/api', authRoutes);
app.use('/api', profileRoutes);
app.use('/api', geoRoutes);

const port = process.env.PORT || 3000;
app.listen(port, () => {
  console.log(`REVORA server running at http://localhost:${port}`);
});
