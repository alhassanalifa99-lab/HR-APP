// ==========================================
// GEOFENCE HR SYSTEM - NODE.JS BACKEND
// ==========================================

// server.js
const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');
const bcrypt = require('bcrypt');
const jwt = require('jsonwebtoken');
const nodemailer = require('nodemailer');
const crypto = require('crypto');

const app = express();
const PORT = process.env.PORT || 3001;
const JWT_SECRET = process.env.JWT_SECRET || 'your-secret-key-change-in-production';

// Database configuration
const pool = new Pool({
  user: process.env.DB_USER || 'postgres',
  host: process.env.DB_HOST || 'localhost',
  database: process.env.DB_NAME || 'geofence_hr',
  password: process.env.DB_PASSWORD || 'password',
  port: process.env.DB_PORT || 5432,
});

// Middleware
app.use(cors());
app.use(express.json());

// Email configuration (for magic links)
const transporter = nodemailer.createTransport({
  host: process.env.SMTP_HOST,
  port: process.env.SMTP_PORT,
  auth: {
    user: process.env.SMTP_USER,
    pass: process.env.SMTP_PASS,
  },
});

// ==========================================
// AUTHENTICATION MIDDLEWARE
// ==========================================

const authenticateToken = (req, res, next) => {
  const authHeader = req.headers['authorization'];
  const token = authHeader && authHeader.split(' ')[1];

  if (!token) {
    return res.status(401).json({ error: 'Access token required' });
  }

  jwt.verify(token, JWT_SECRET, (err, user) => {
    if (err) return res.status(403).json({ error: 'Invalid token' });
    req.user = user;
    next();
  });
};

const requireManager = (req, res, next) => {
  if (req.user.role !== 'manager' && req.user.role !== 'admin') {
    return res.status(403).json({ error: 'Manager access required' });
  }
  next();
};

// ==========================================
// GEOSPATIAL HELPER FUNCTIONS
// ==========================================

// Point-in-Polygon check using PostGIS
const isPointInGeofence = async (latitude, longitude, siteId) => {
  const query = `
    SELECT ST_Contains(
      geofence_area::geometry,
      ST_SetSRID(ST_MakePoint($1, $2), 4326)::geometry
    ) AS inside
    FROM sites
    WHERE id = $3
  `;
  
  const result = await pool.query(query, [longitude, latitude, siteId]);
  return result.rows[0]?.inside || false;
};

// ==========================================
// AUTHENTICATION ROUTES
// ==========================================

// Request Magic Link
app.post('/api/auth/request-magic-link', async (req, res) => {
  try {
    const { email } = req.body;

    if (!email) {
      return res.status(400).json({ error: 'Email is required' });
    }

    // Check if user exists
    const userResult = await pool.query(
      'SELECT id, email, full_name, company_id FROM users WHERE email = $1 AND is_active = TRUE',
      [email]
    );

    if (userResult.rows.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }

    const user = userResult.rows[0];

    // Generate magic link token
    const token = crypto.randomBytes(32).toString('hex');
    const expiresAt = new Date(Date.now() + 15 * 60 * 1000); // 15 minutes

    // Store token
    await pool.query(
      'INSERT INTO magic_links (user_id, token, expires_at) VALUES ($1, $2, $3)',
      [user.id, token, expiresAt]
    );

    // Send email
    const magicLink = `${process.env.FRONTEND_URL}/auth/verify?token=${token}`;
    
    await transporter.sendMail({
      from: process.env.SMTP_FROM,
      to: email,
      subject: 'Your Login Link - Geofence HR',
      html: `
        <h2>Login to Geofence HR</h2>
        <p>Hello ${user.full_name},</p>
        <p>Click the link below to login (expires in 15 minutes):</p>
        <a href="${magicLink}">${magicLink}</a>
      `,
    });

    res.json({ message: 'Magic link sent to your email' });
  } catch (error) {
    console.error('Magic link error:', error);
    res.status(500).json({ error: 'Failed to send magic link' });
  }
});

// Verify Magic Link
app.post('/api/auth/verify-magic-link', async (req, res) => {
  try {
    const { token } = req.body;

    // Get token from database
    const tokenResult = await pool.query(
      `SELECT ml.*, u.id as user_id, u.email, u.full_name, u.role, u.company_id
       FROM magic_links ml
       JOIN users u ON ml.user_id = u.id
       WHERE ml.token = $1 AND ml.used_at IS NULL AND ml.expires_at > NOW()`,
      [token]
    );

    if (tokenResult.rows.length === 0) {
      return res.status(400).json({ error: 'Invalid or expired token' });
    }

    const tokenData = tokenResult.rows[0];

    // Mark token as used
    await pool.query(
      'UPDATE magic_links SET used_at = NOW() WHERE token = $1',
      [token]
    );

    // Update last login
    await pool.query(
      'UPDATE users SET last_login = NOW() WHERE id = $1',
      [tokenData.user_id]
    );

    // Generate JWT
    const accessToken = jwt.sign(
      {
        userId: tokenData.user_id,
        email: tokenData.email,
        role: tokenData.role,
        companyId: tokenData.company_id,
      },
      JWT_SECRET,
      { expiresIn: '24h' }
    );

    res.json({
      accessToken,
      user: {
        id: tokenData.user_id,
        email: tokenData.email,
        name: tokenData.full_name,
        role: tokenData.role,
        companyId: tokenData.company_id,
      },
    });
  } catch (error) {
    console.error('Verify token error:', error);
    res.status(500).json({ error: 'Failed to verify token' });
  }
});

// ==========================================
// EMPLOYEE MANAGEMENT ROUTES (MANAGER ONLY)
// ==========================================

// Get all employees for company
app.get('/api/manager/employees', authenticateToken, requireManager, async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT id, email, full_name, role, assigned_sites, is_active, 
              created_at, last_login
       FROM users
       WHERE company_id = $1
       ORDER BY full_name ASC`,
      [req.user.companyId]
    );

    res.json(result.rows);
  } catch (error) {
    console.error('Get employees error:', error);
    res.status(500).json({ error: 'Failed to fetch employees' });
  }
});

// Create new employee
app.post('/api/manager/employees', authenticateToken, requireManager, async (req, res) => {
  try {
    const { email, fullName, role, assignedSites } = req.body;

    // Validation
    if (!email || !fullName) {
      return res.status(400).json({ error: 'Email and full name are required' });
    }

    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      return res.status(400).json({ error: 'Invalid email format' });
    }

    // Check for duplicate email in company
    const existingUser = await pool.query(
      'SELECT id FROM users WHERE company_id = $1 AND email = $2',
      [req.user.companyId, email]
    );

    if (existingUser.rows.length > 0) {
      return res.status(400).json({ error: 'Email already exists in your company' });
    }

    // Insert new employee
    const result = await pool.query(
      `INSERT INTO users (company_id, email, full_name, role, assigned_sites, is_active)
       VALUES ($1, $2, $3, $4, $5, TRUE)
       RETURNING id, email, full_name, role, assigned_sites, is_active, created_at`,
      [req.user.companyId, email, fullName, role || 'employee', assignedSites || []]
    );

    res.status(201).json(result.rows[0]);
  } catch (error) {
    console.error('Create employee error:', error);
    res.status(500).json({ error: 'Failed to create employee' });
  }
});

// Update employee
app.put('/api/manager/employees/:employeeId', authenticateToken, requireManager, async (req, res) => {
  try {
    const { employeeId } = req.params;
    const { email, fullName, role, assignedSites, isActive } = req.body;

    // Verify employee belongs to manager's company
    const employeeCheck = await pool.query(
      'SELECT id FROM users WHERE id = $1 AND company_id = $2',
      [employeeId, req.user.companyId]
    );

    if (employeeCheck.rows.length === 0) {
      return res.status(404).json({ error: 'Employee not found' });
    }

    // Build dynamic update query
    const updates = [];
    const values = [];
    let paramCount = 1;

    if (email !== undefined) {
      // Check for duplicate email
      const dupCheck = await pool.query(
        'SELECT id FROM users WHERE email = $1 AND company_id = $2 AND id != $3',
        [email, req.user.companyId, employeeId]
      );
      if (dupCheck.rows.length > 0) {
        return res.status(400).json({ error: 'Email already exists' });
      }
      updates.push(`email = $${paramCount++}`);
      values.push(email);
    }

    if (fullName !== undefined) {
      updates.push(`full_name = $${paramCount++}`);
      values.push(fullName);
    }

    if (role !== undefined) {
      updates.push(`role = $${paramCount++}`);
      values.push(role);
    }

    if (assignedSites !== undefined) {
      updates.push(`assigned_sites = $${paramCount++}`);
      values.push(assignedSites);
    }

    if (isActive !== undefined) {
      updates.push(`is_active = $${paramCount++}`);
      values.push(isActive);
    }

    updates.push(`updated_at = NOW()`);
    values.push(employeeId);

    const query = `
      UPDATE users 
      SET ${updates.join(', ')}
      WHERE id = $${paramCount}
      RETURNING id, email, full_name, role, assigned_sites, is_active, updated_at
    `;

    const result = await pool.query(query, values);
    res.json(result.rows[0]);
  } catch (error) {
    console.error('Update employee error:', error);
    res.status(500).json({ error: 'Failed to update employee' });
  }
});

// Assign employee to site(s)
app.post('/api/manager/employees/:employeeId/assign-sites', authenticateToken, requireManager, async (req, res) => {
  try {
    const { employeeId } = req.params;
    const { siteIds } = req.body; // Array of site IDs

    if (!Array.isArray(siteIds)) {
      return res.status(400).json({ error: 'siteIds must be an array' });
    }

    // Verify employee belongs to company
    const employeeCheck = await pool.query(
      'SELECT id, assigned_sites FROM users WHERE id = $1 AND company_id = $2',
      [employeeId, req.user.companyId]
    );

    if (employeeCheck.rows.length === 0) {
      return res.status(404).json({ error: 'Employee not found' });
    }

    // Verify all sites belong to company
    const sitesCheck = await pool.query(
      'SELECT id FROM sites WHERE id = ANY($1) AND company_id = $2',
      [siteIds, req.user.companyId]
    );

    if (sitesCheck.rows.length !== siteIds.length) {
      return res.status(400).json({ error: 'Some sites do not belong to your company' });
    }

    // Update assigned sites
    const result = await pool.query(
      `UPDATE users 
       SET assigned_sites = $1, updated_at = NOW()
       WHERE id = $2
       RETURNING id, email, full_name, assigned_sites`,
      [siteIds, employeeId]
    );

    res.json(result.rows[0]);
  } catch (error) {
    console.error('Assign sites error:', error);
    res.status(500).json({ error: 'Failed to assign sites' });
  }
});

// Delete employee
app.delete('/api/manager/employees/:employeeId', authenticateToken, requireManager, async (req, res) => {
  try {
    const { employeeId } = req.params;

    // Verify employee belongs to company
    const employeeCheck = await pool.query(
      'SELECT id FROM users WHERE id = $1 AND company_id = $2',
      [employeeId, req.user.companyId]
    );

    if (employeeCheck.rows.length === 0) {
      return res.status(404).json({ error: 'Employee not found' });
    }

    // Delete employee (CASCADE will handle attendance_logs)
    await pool.query('DELETE FROM users WHERE id = $1', [employeeId]);

    res.json({ message: 'Employee deleted successfully' });
  } catch (error) {
    console.error('Delete employee error:', error);
    res.status(500).json({ error: 'Failed to delete employee' });
  }
});

// Bulk import employees
app.post('/api/manager/employees/bulk-import', authenticateToken, requireManager, async (req, res) => {
  try {
    const { employees } = req.body; // Array of employee objects

    if (!Array.isArray(employees)) {
      return res.status(400).json({ error: 'employees must be an array' });
    }

    const imported = [];
    const errors = [];
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

    for (let i = 0; i < employees.length; i++) {
      const emp = employees[i];
      
      try {
        // Validate
        if (!emp.email || !emp.fullName) {
          errors.push({ row: i + 1, error: 'Missing email or name' });
          continue;
        }

        if (!emailRegex.test(emp.email)) {
          errors.push({ row: i + 1, error: `Invalid email: ${emp.email}` });
          continue;
        }

        // Check duplicate
        const dupCheck = await pool.query(
          'SELECT id FROM users WHERE email = $1 AND company_id = $2',
          [emp.email, req.user.companyId]
        );

        if (dupCheck.rows.length > 0) {
          errors.push({ row: i + 1, error: `Email already exists: ${emp.email}` });
          continue;
        }

        // Insert
        const result = await pool.query(
          `INSERT INTO users (company_id, email, full_name, role, assigned_sites, is_active)
           VALUES ($1, $2, $3, $4, $5, TRUE)
           RETURNING id, email, full_name`,
          [req.user.companyId, emp.email, emp.fullName, emp.role || 'employee', emp.assignedSites || []]
        );

        imported.push(result.rows[0]);
      } catch (err) {
        errors.push({ row: i + 1, error: err.message });
      }
    }

    res.json({
      imported: imported.length,
      errors: errors.length,
      details: { imported, errors },
    });
  } catch (error) {
    console.error('Bulk import error:', error);
    res.status(500).json({ error: 'Failed to import employees' });
  }
});

// ==========================================
// CLOCK-IN/OUT ROUTES
// ==========================================

// Clock In
app.post('/api/attendance/clock-in', authenticateToken, async (req, res) => {
  try {
    const { siteId, latitude, longitude, accuracy } = req.body;

    if (!siteId || !latitude || !longitude) {
      return res.status(400).json({ error: 'siteId, latitude, and longitude are required' });
    }

    // Check if user is assigned to this site
    const userCheck = await pool.query(
      'SELECT assigned_sites FROM users WHERE id = $1',
      [req.user.userId]
    );

    if (!userCheck.rows[0].assigned_sites.includes(siteId)) {
      return res.status(403).json({ error: 'You are not assigned to this site' });
    }

    // Check if already clocked in
    const activeSession = await pool.query(
      'SELECT id FROM attendance_logs WHERE user_id = $1 AND is_active = TRUE',
      [req.user.userId]
    );

    if (activeSession.rows.length > 0) {
      return res.status(400).json({ error: 'Already clocked in at another site' });
    }

    // Verify location is inside geofence
    const isInside = await isPointInGeofence(latitude, longitude, siteId);

    if (!isInside) {
      return res.status(403).json({ error: 'You must be inside the site boundary to clock in' });
    }

    // Create attendance log
    const now = new Date();
    const heartbeatExpires = new Date(now.getTime() + 2 * 60 * 60 * 1000); // 2 hours

    const result = await pool.query(
      `INSERT INTO attendance_logs (
        user_id, site_id, company_id, 
        clock_in_time, clock_in_location, clock_in_accuracy_meters,
        heartbeat_expires, is_active
      ) VALUES ($1, $2, $3, $4, ST_SetSRID(ST_MakePoint($5, $6), 4326), $7, $8, TRUE)
      RETURNING id, clock_in_time, heartbeat_expires`,
      [req.user.userId, siteId, req.user.companyId, now, longitude, latitude, accuracy, heartbeatExpires]
    );

    res.status(201).json({
      attendanceLogId: result.rows[0].id,
      clockInTime: result.rows[0].clock_in_time,
      heartbeatExpires: result.rows[0].heartbeat_expires,
      message: 'Clocked in successfully',
    });
  } catch (error) {
    console.error('Clock-in error:', error);
    res.status(500).json({ error: 'Failed to clock in' });
  }
});

// Renew Heartbeat
app.post('/api/attendance/renew-heartbeat', authenticateToken, async (req, res) => {
  try {
    const { attendanceLogId, latitude, longitude } = req.body;

    // Get active session
    const session = await pool.query(
      `SELECT al.*, s.geofence_area
       FROM attendance_logs al
       JOIN sites s ON al.site_id = s.id
       WHERE al.id = $1 AND al.user_id = $2 AND al.is_active = TRUE`,
      [attendanceLogId, req.user.userId]
    );

    if (session.rows.length === 0) {
      return res.status(404).json({ error: 'No active session found' });
    }

    // Verify still inside geofence
    const isInside = await isPointInGeofence(latitude, longitude, session.rows[0].site_id);

    if (!isInside) {
      // Auto clock-out
      await pool.query(
        `UPDATE attendance_logs
         SET clock_out_time = NOW(),
             clock_out_location = ST_SetSRID(ST_MakePoint($1, $2), 4326),
             clock_out_reason = 'auto_geofence_exit',
             is_active = FALSE
         WHERE id = $3`,
        [longitude, latitude, attendanceLogId]
      );

      return res.status(403).json({ error: 'You are outside the site boundary. Auto-clocked out.' });
    }

    // Extend heartbeat
    const newExpiry = new Date(Date.now() + 2 * 60 * 60 * 1000);

    await pool.query(
      `UPDATE attendance_logs
       SET heartbeat_expires = $1,
           last_heartbeat_time = NOW(),
           heartbeat_renewals_count = heartbeat_renewals_count + 1
       WHERE id = $2`,
      [newExpiry, attendanceLogId]
    );

    res.json({
      newExpiry,
      message: 'Presence renewed for 2 hours',
    });
  } catch (error) {
    console.error('Renew heartbeat error:', error);
    res.status(500).json({ error: 'Failed to renew heartbeat' });
  }
});

// Clock Out
app.post('/api/attendance/clock-out', authenticateToken, async (req, res) => {
  try {
    const { attendanceLogId, latitude, longitude } = req.body;

    const result = await pool.query(
      `UPDATE attendance_logs
       SET clock_out_time = NOW(),
           clock_out_location = ST_SetSRID(ST_MakePoint($1, $2), 4326),
           clock_out_reason = 'manual',
           is_active = FALSE
       WHERE id = $3 AND user_id = $4 AND is_active = TRUE
       RETURNING id, clock_in_time, clock_out_time`,
      [longitude, latitude, attendanceLogId, req.user.userId]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'No active session found' });
    }

    res.json({
      message: 'Clocked out successfully',
      clockInTime: result.rows[0].clock_in_time,
      clockOutTime: result.rows[0].clock_out_time,
    });
  } catch (error) {
    console.error('Clock-out error:', error);
    res.status(500).json({ error: 'Failed to clock out' });
  }
});

// Geofence Exit Handler (called by mobile app)
app.post('/api/geofence/exit', authenticateToken, async (req, res) => {
  try {
    const { attendanceLogId, latitude, longitude } = req.body;

    // Log geofence event
    await pool.query(
      `INSERT INTO geofence_events (user_id, site_id, attendance_log_id, event_type, event_location)
       SELECT user_id, site_id, id, 'exit', ST_SetSRID(ST_MakePoint($1, $2), 4326)
       FROM attendance_logs WHERE id = $3`,
      [longitude, latitude, attendanceLogId]
    );

    // Auto clock-out
    const result = await pool.query(
      `UPDATE attendance_logs
       SET clock_out_time = NOW(),
           clock_out_location = ST_SetSRID(ST_MakePoint($1, $2), 4326),
           clock_out_reason = 'auto_geofence_exit',
           is_active = FALSE
       WHERE id = $3 AND user_id = $4 AND is_active = TRUE
       RETURNING id`,
      [longitude, latitude, attendanceLogId, req.user.userId]
    );

    res.json({
      message: 'Auto-clocked out due to geofence exit',
      success: result.rows.length > 0,
    });
  } catch (error) {
    console.error('Geofence exit error:', error);
    res.status(500).json({ error: 'Failed to process geofence exit' });
  }
});

// ==========================================
// BACKGROUND JOB: Check Expired Heartbeats
// ==========================================

setInterval(async () => {
  try {
    const result = await pool.query(
      `UPDATE attendance_logs
       SET clock_out_time = NOW(),
           clock_out_reason = 'auto_heartbeat_expired',
           is_active = FALSE
       WHERE is_active = TRUE AND heartbeat_expires < NOW()
       RETURNING id, user_id`
    );

    if (result.rows.length > 0) {
      console.log(`Auto-clocked out ${result.rows.length} expired sessions`);
      // TODO: Send push notifications to affected users
    }
  } catch (error) {
    console.error('Heartbeat check error:', error);
  }
}, 60000); // Run every 60 seconds

// ==========================================
// START SERVER
// ==========================================

app.listen(PORT, () => {
  console.log(`🚀 Geofence HR API running on port ${PORT}`);
});

// Export for testing
module.exports = app;
