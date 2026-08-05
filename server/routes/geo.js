const express = require('express');
const router = express.Router();

// Luzon regions only - fixed, closed set. Province/City/Barangay are no
// longer pickable from a dropdown (registrants type them in manually), so
// this is the only geography lookup left; served as a static list rather
// than a query so the dropdown is always complete regardless of what's
// already in dbo.Region.
const PH_REGIONS = [
  'NCR', 'CAR', 'Region I', 'Region II', 'Region III', 'Region IV-A', 'MIMAROPA', 'Region V'
];

router.get('/geo/regions', (req, res) => {
  res.json(PH_REGIONS);
});

module.exports = router;
module.exports.PH_REGIONS = PH_REGIONS;
