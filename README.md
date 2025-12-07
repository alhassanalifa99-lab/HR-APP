# Geofence HR System - Complete Implementation Guide

## 🎯 Overview

A production-ready Geospatial Proof-of-Presence HR Time & Attendance System built with Node.js, PostgreSQL + PostGIS, and React. Features include:

- ✅ **Geofenced Clock-In/Out** - Location-validated attendance
- ✅ **2-Hour Heartbeat System** - Proof-of-presence with auto-logout
- ✅ **Real-time Geofence Exit Detection** - Automatic clock-out
- ✅ **Manager Controls** - Edit usernames, assign employees to sites
- ✅ **Bulk Import** - CSV upload for multiple employees
- ✅ **Magic Link Authentication** - Passwordless email login
- ✅ **Multi-tenant Architecture** - Support multiple companies

---

## 📁 Project Structure

```
geofence-hr-system/
├── backend/
│   ├── server.js                 # Main Express server
│   ├── database_setup.sql        # PostgreSQL schema
│   ├── package.json              # Dependencies
│   └── .env                      # Environment variables
├── frontend/
│   ├── src/
│   │   ├── components/
│   │   │   └── GeofenceHRApp.jsx # Main React app
│   │   ├── api/
│   │   │   └── client.js         # API integration
│   │   └── App.js
│   └── package.json
└── README.md
```

---

## 🚀 Quick Start

### 1. Install Prerequisites

**Required:**
- Node.js 18+ ([Download](https://nodejs.org/))
- PostgreSQL 14+ with PostGIS ([Installation Guide](#postgresql-installation))
- npm or yarn

**Optional:**
- Docker (for containerized deployment)

---

### 2. Backend Setup

#### Step 1: Install PostgreSQL + PostGIS

**Ubuntu/Debian:**
```bash
sudo apt update
sudo apt install postgresql postgresql-contrib postgis
sudo systemctl start postgresql
```

**macOS (Homebrew):**
```bash
brew install postgresql postgis
brew services start postgresql
```

**Windows:**
Download and install from [PostgreSQL Downloads](https://www.postgresql.org/download/)

#### Step 2: Create Database

```bash
# Connect to PostgreSQL
sudo -u postgres psql

# Create database
CREATE DATABASE geofence_hr;

# Connect to database
\c geofence_hr

# Enable PostGIS
CREATE EXTENSION postgis;

# Exit
\q
```

#### Step 3: Clone & Install Dependencies

```bash
cd backend/
npm install
```

#### Step 4: Configure Environment Variables

Create `.env` file in `backend/` directory:

```env
# Database Configuration
DB_USER=postgres
DB_HOST=localhost
DB_NAME=geofence_hr
DB_PASSWORD=your_database_password
DB_PORT=5432

# JWT Secret (Generate strong random string)
JWT_SECRET=your-super-secret-jwt-key-change-this-in-production

# Email Configuration (for Magic Links)
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASS=your-gmail-app-password
SMTP_FROM="Geofence HR <noreply@yourcompany.com>"

# Frontend URL
FRONTEND_URL=http://localhost:3000

# Server Port
PORT=3001
```

**Gmail App Password Setup:**
1. Go to Google Account → Security
2. Enable 2-Factor Authentication
3. Generate App Password for "Mail"
4. Use that password in `SMTP_PASS`

#### Step 5: Run Database Setup

```bash
npm run db:setup
```

This creates all tables, indexes, and sample data (1 manager, 2 sites, no employees).

#### Step 6: Start Backend Server

```bash
npm run dev
```

Server runs on `http://localhost:3001`

---

### 3. Frontend Setup

#### Step 1: Install Dependencies

```bash
cd frontend/
npm install
```

#### Step 2: Configure API URL

Create `.env` file in `frontend/` directory:

```env
REACT_APP_API_URL=http://localhost:3001/api
```

#### Step 3: Start Frontend

```bash
npm start
```

Frontend runs on `http://localhost:3000`

---

## 👨‍💼 Manager Features

### 1. Edit Employee Username

**Via API:**
```bash
curl -X PUT http://localhost:3001/api/manager/employees/{employeeId} \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"fullName": "Updated Name"}'
```

**Via UI:**
1. Login as Manager
2. Go to **Employees** tab
3. Click **Edit** (pencil icon) next to employee
4. Update **Full Name (Username)** field
5. Click **Update Employee**

---

### 2. Assign Employee to Sites

**Via API:**
```bash
curl -X POST http://localhost:3001/api/manager/employees/{employeeId}/assign-sites \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"siteIds": ["site-uuid-1", "site-uuid-2"]}'
```

**Via UI:**
1. Login as Manager
2. Go to **Employees** tab
3. Click **Edit** on employee
4. Check/uncheck sites in **Assign to Sites** section
5. Click **Update Employee**

**Important:** Employees can ONLY clock in at sites they're assigned to.

---

### 3. Bulk Import Employees

**CSV Format:**
```csv
name,email,role,site_ids
John Doe,john@company.com,employee,site-uuid-1;site-uuid-2
Jane Smith,jane@company.com,employee,site-uuid-1
Mike Manager,mike@company.com,manager,site-uuid-1;site-uuid-2
```

**Via UI:**
1. Go to **Employees** tab
2. Click **Bulk Import** button
3. Click **Download CSV Template** for format
4. Paste CSV data or upload file
5. Click **Import Employees**
6. Review success/error report

**Via API:**
```bash
curl -X POST http://localhost:3001/api/manager/employees/bulk-import \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "employees": [
      {
        "email": "john@company.com",
        "fullName": "John Doe",
        "role": "employee",
        "assignedSites": ["site-uuid-1"]
      }
    ]
  }'
```

---

## 🔑 Authentication Flow

### 1. Request Magic Link

```bash
curl -X POST http://localhost:3001/api/auth/request-magic-link \
  -H "Content-Type: application/json" \
  -d '{"email": "manager@techcorp.com"}'
```

Email with login link will be sent.

### 2. Verify Magic Link

Click link in email OR use token:

```bash
curl -X POST http://localhost:3001/api/auth/verify-magic-link \
  -H "Content-Type: application/json" \
  -d '{"token": "TOKEN_FROM_EMAIL"}'
```

Response includes JWT token and user info.

### 3. Use JWT for Authenticated Requests

```bash
curl -X GET http://localhost:3001/api/manager/employees \
  -H "Authorization: Bearer YOUR_JWT_TOKEN"
```

---

## 📍 Geofencing Logic

### Clock-In Validation

1. Employee requests clock-in with GPS coordinates
2. Backend validates point is inside site's geofence polygon (PostGIS `ST_Contains`)
3. If inside → Clock-in succeeds
4. If outside → Returns error: "You must be inside the site boundary"

### 2-Hour Heartbeat System

1. On clock-in, `heartbeat_expires` set to `NOW() + 2 hours`
2. Background job runs every 60 seconds checking for expired heartbeats
3. If expired → Auto clock-out with reason `auto_heartbeat_expired`
4. Employee must click **Renew Presence** before expiry to extend

### Geofence Exit Detection

**Mobile App Integration:**
1. Native geofencing APIs monitor boundary
2. On exit event → POST to `/api/geofence/exit`
3. Backend immediately clocks out with reason `auto_geofence_exit`
4. Logged in `geofence_events` table for audit

---

## 🗄️ Database Management

### View All Employees
```sql
SELECT id, full_name, email, role, assigned_sites 
FROM users 
WHERE company_id = 'your-company-uuid';
```

### Remove Dummy Attendance Data
```sql
DELETE FROM geofence_events;
DELETE FROM attendance_logs;
```

### Remove All Employees (Keep Manager)
```sql
DELETE FROM users WHERE role = 'employee';
```

### Complete Database Reset
```bash
npm run db:reset
```

---

## 🧪 Testing

### Test Magic Link Flow
1. Request link: `npm run test:magic-link`
2. Check terminal for token
3. Verify: `npm run test:verify {TOKEN}`

### Test Geofence Validation
```bash
# Inside geofence (should succeed)
curl -X POST http://localhost:3001/api/attendance/clock-in \
  -H "Authorization: Bearer YOUR_JWT" \
  -d '{
    "siteId": "SITE_UUID",
    "latitude": 6.6890,
    "longitude": -1.6237,
    "accuracy": 10
  }'

# Outside geofence (should fail)
curl -X POST http://localhost:3001/api/attendance/clock-in \
  -H "Authorization: Bearer YOUR_JWT" \
  -d '{
    "siteId": "SITE_UUID",
    "latitude": 6.7000,
    "longitude": -1.7000,
    "accuracy": 10
  }'
```

---

## 🚢 Production Deployment

### Environment Variables

```env
# Production Database
DB_HOST=your-rds-endpoint.rds.amazonaws.com
DB_PASSWORD=strong-random-password

# Strong JWT Secret
JWT_SECRET=$(openssl rand -base64 32)

# Production Email Service (SendGrid, AWS SES, etc.)
SMTP_HOST=smtp.sendgrid.net
SMTP_USER=apikey
SMTP_PASS=your-sendgrid-api-key

# Production Frontend URL
FRONTEND_URL=https://hr.yourcompany.com
```

### Security Checklist

- [ ] Change default JWT_SECRET
- [ ] Use environment variables (not hardcoded)
- [ ] Enable HTTPS/SSL
- [ ] Set up PostgreSQL SSL connection
- [ ] Configure CORS for production domain only
- [ ] Enable rate limiting (already included)
- [ ] Set up database backups (AWS RDS automated backups)
- [ ] Configure CloudWatch/DataDog monitoring
- [ ] Enable helmet security headers (already included)
- [ ] Set up fail2ban for brute force protection

### Deployment Options

**Option 1: AWS**
- EC2/Elastic Beanstalk for Node.js
- RDS PostgreSQL with PostGIS
- CloudFront + S3 for React frontend
- SES for email
- Lambda for background jobs

**Option 2: Heroku**
```bash
heroku create geofence-hr-api
heroku addons:create heroku-postgresql:standard-0
heroku config:set JWT_SECRET=your-secret
git push heroku main
```

**Option 3: Docker**
```bash
docker-compose up -d
```

---

## 📊 Monitoring

### Key Metrics to Track

1. **Geofence Validation Success Rate**
   - Target: > 95% inside boundary
   
2. **Heartbeat Expiry Rate**
   - High rate indicates UX issues
   
3. **Average Response Time**
   - Clock-in: < 500ms
   - Heartbeat renewal: < 200ms

4. **Database Query Performance**
   - ST_Contains queries: < 100ms

### Logging

Add structured logging:
```javascript
const winston = require('winston');

const logger = winston.createLogger({
  level: 'info',
  format: winston.format.json(),
  transports: [
    new winston.transports.File({ filename: 'error.log', level: 'error' }),
    new winston.transports.File({ filename: 'combined.log' })
  ]
});
```

---

## 🐛 Troubleshooting

### Issue: Magic Link not received

**Solution:**
1. Check SMTP credentials in `.env`
2. Verify email isn't in spam
3. Check console logs for email errors
4. Test SMTP connection: `npm run test:email`

### Issue: Geofence validation always fails

**Solution:**
1. Verify PostGIS is installed: `SELECT PostGIS_version();`
2. Check geofence polygon coordinates are correct (lon, lat order)
3. Verify GPS coordinates are WGS84 (SRID 4326)
4. Test point-in-polygon query directly in psql

### Issue: Background job not running

**Solution:**
1. Check server logs for errors
2. Verify `setInterval` is not blocked
3. Consider using node-cron for production
4. Set up external monitoring (cron-job.org)

---

## 📚 API Reference

Complete API documentation: [API_DOCS.md](./API_DOCS.md)

Quick reference:

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/auth/request-magic-link` | Request login email |
| POST | `/api/auth/verify-magic-link` | Login with token |
| GET | `/api/manager/employees` | List employees |
| POST | `/api/manager/employees` | Create employee |
| PUT | `/api/manager/employees/:id` | Update employee/username |
| POST | `/api/manager/employees/:id/assign-sites` | Assign to sites |
| DELETE | `/api/manager/employees/:id` | Delete employee |
| POST | `/api/attendance/clock-in` | Clock in |
| POST | `/api/attendance/renew-heartbeat` | Renew presence |
| POST | `/api/attendance/clock-out` | Clock out |
| POST | `/api/geofence/exit` | Geofence exit event |

---

## 🤝 Support

- **Issues:** [GitHub Issues](https://github.com/yourcompany/geofence-hr/issues)
- **Email:** support@yourcompany.com
- **Documentation:** [Full Docs](https://docs.yourcompany.com/geofence-hr)

---

## 📄 License

MIT License - See [LICENSE](./LICENSE) file

---

## ✅ Next Steps

1. [ ] Complete backend and frontend setup
2. [ ] Test magic link authentication
3. [ ] Add your first employee via bulk import
4. [ ] Configure geofence boundaries for your sites
5. [ ] Test clock-in/out flow
6. [ ] Set up production environment
7. [ ] Integrate mobile app with native geofencing

---

**Built with ❤️ for accurate workforce management**
