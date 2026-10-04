# RUBO Banking — MiniBank Demo

**RUBO Banking** is a local banking-style demonstration application built with Flask.

> **Demo only. No real money or bank connections.**

The application uses banking-style terminology, transaction references, balances, and account management features for realism, but **all money and transactions are local simulation data**. No real bank, payment provider, card network, or external financial service is connected.

---

## Features

### Banking

* User accounts and profiles
* Local simulated balances
* User-to-user transfers
* Transfer receipts
* Transaction history
* Double-entry ledger records
* Transfer notes
* Duplicate-transfer protection
* Notifications
* Beneficiaries
* Scheduled and recurring transfers
* Transfer cancellation window
* CSV statements
* Singapore-time display for dates and times

### Transfer PIN

Transfers are protected by a **6-digit Transfer PIN**.

* Transfer PIN can be configured from **Accounts**
* PINs are stored using password hashing
* A PIN is required before a transfer is executed
* Transfers first go through a confirmation/review screen
* Incorrect PINs do not move any money
* Changing an existing PIN requires the current PIN
* The PIN is never stored as plain text

The transfer flow is:

```text
Enter transfer details
        ↓
Review transfer
        ↓
Enter 6-digit Transfer PIN
        ↓
Validate PIN
        ↓
Execute simulated transfer
        ↓
Generate receipt
```

### Responsive Banking UI

The interface supports both desktop and mobile-style layouts.

* Responsive navigation
* Mobile-friendly transfer forms
* Responsive account pages
* Mobile-friendly transaction views
* Banking-style cards and panels
* Desktop interface remains supported

---

## Account Types

### Standard

Normal banking access, including:

* Transfers
* Messages
* Profile access
* Account settings

### Developer

Developer accounts have management permissions in addition to normal account functionality.

Developer tools include:

* System health information
* Sandbox user generation
* Feature flags
* Scoped API keys
* Recent audit activity
* Developer console

### Admin

Administrators have management permissions including:

* User creation
* Balance management
* Account resets
* Enable/disable accounts
* Account deletion
* Permission management
* User impersonation
* Privileged transfers
* Audit-log access

The legacy `is_admin` flag remains supported for existing databases and is treated as Admin access.

---

## Management Features

Management users can impersonate enabled accounts from the Admin panel.

The application:

* Clearly identifies an impersonated session
* Keeps the original management identity separately
* Allows the administrator to return to the management account
* Safely ends stale or disabled sessions
* Records impersonation starts and ends in `AuditLog`

Management users also have a privileged-transfer system requiring:

* An enabled source account
* An enabled recipient account
* A positive transfer amount
* Sufficient balance
* A reason for the transfer

The balance changes, transaction, and audit record are committed together.

---

## Messaging

The messaging system supports:

* Direct messages
* Creator-owned group chats
* Group owners and moderators
* Adding/removing enabled members
* Reactions
* URL attachments
* `@mentions`
* Read receipts
* Unread counters

Each member has an independent read state, so reading one conversation does not incorrectly clear another conversation's unread count.

---

## Admin and Developer Systems

The application includes:

* Fine-grained permission records
* Audited impersonation
* Pending privileged-transfer approval requests
* Legacy privileged-transfer support
* Admin and Developer role combinations
* Management-only balance viewing
* Audited demo-check deposits
* Searchable audit logs
* Socket.IO notifications
* Feature flags
* Scoped API keys
* Sandbox user generation
* System health tools
* Developer console

Admin and Developer roles are stored using `UserRole` records.

The legacy `account_type` and `is_admin` columns remain readable for compatibility with older databases.

Users may hold both Admin and Developer roles.

---

## Database

RUBO Banking uses a **persistent database**.

This means that restarting Flask does **not** reset the users, balances, transactions, or other stored data.

For example:

```cmd
python -m flask --app app run --host=0.0.0.0 --port=5000
```

Stopping the server with:

```text
CTRL+C
```

only stops Flask. It does **not** delete the database.

This is intentional.

### Starting with a fresh database

If a completely fresh demo database is required:

1. Stop Flask with `CTRL+C`.
2. Identify the database file.
3. Back it up if necessary.
4. Delete the correct database file.
5. Start Flask again.

To find SQLite database files on Windows:

```cmd
dir /s /b *.db
```

If no `.db` file is found, also check:

```cmd
dir /s /b *.sqlite
dir /s /b *.sqlite3
```

**Do not delete a database file until you have confirmed that it belongs to RUBO Banking.**

---

## Database Configuration

The application can use a local SQLite database for development.

A `DATABASE_URL` environment variable can also be used to connect the application to a supported external database such as PostgreSQL.

Example:

```text
DATABASE_URL=postgresql://username:password@host/database
```

Never commit real database passwords or credentials to GitHub.

---

## Time Zones

All timestamps are stored as UTC-aware values where supported by the database.

The shared `sgt` template filter converts displayed timestamps to:

```text
SGT / Asia/Singapore (UTC+8)
```

This applies to:

* Transactions
* Messages
* Audit events
* Notifications
* Scheduled transfers
* Statements
* Other displayed timestamps

Datetime values entered through the UI, such as scheduled-transfer times, are interpreted as Singapore time and normalized to UTC for storage.

---

## Running on Windows

Open Command Prompt in the project directory.

### 1. Create the virtual environment

```cmd
python -m venv venv
```

### 2. Activate it

```cmd
venv\Scripts\activate
```

### 3. Install dependencies

```cmd
python -m pip install --upgrade pip
pip install -r requirements.txt
```

### 4. Configure the application

For Command Prompt:

```cmd
set ADMIN_USERNAME=admin
set ADMIN_PASSWORD=ChooseASecretPassword123
set SECRET_KEY=LongRandomSecretKeyReplaceThis
```

For a fresh database, `ADMIN_USERNAME`, `ADMIN_PASSWORD`, and `SECRET_KEY` are required.

Use a strong secret value for `SECRET_KEY` and a strong administrator password.

### 5. Start Flask

```cmd
python -m flask --app app run --host=0.0.0.0 --port=5000
```

Open:

```text
http://127.0.0.1:5000
```

---

## Environment Variables

| Variable         | Purpose                          |
| ---------------- | -------------------------------- |
| `SECRET_KEY`     | Flask session/security key       |
| `ADMIN_USERNAME` | Initial administrator username   |
| `ADMIN_PASSWORD` | Initial administrator password   |
| `DATABASE_URL`   | Optional database connection URL |

Do not publish real passwords, secret keys, API keys, or database credentials.

---

## Demo Security

The application includes several security-oriented demo features:

* Password hashing
* Hashed Transfer PINs
* Login/session management
* Enabled/disabled account checks
* Permission records
* Audit logging
* Duplicate-transfer protection
* Transfer confirmation
* Transfer PIN authorization
* Privileged-transfer validation

This is still a **demo application**, not production banking software.

---

## Important Limitations

No feature sends real:

* Money
* Bank transfers
* Card transactions
* SMS messages
* Financial payments

to external providers.

Scheduled transfers are processed when the owner visits the scheduled-transfers page. A production application should replace this demo behavior with a trusted background worker and proper database migrations.

The PDF statement URL falls back to CSV when a PDF renderer is not installed.

---

## One Checking Account Per User

RUBO Banking uses one checking account per user.

On startup, legacy databases can migrate a user's former secondary-account balance into checking in a single migration transaction.

The old secondary account and internal-transfer records are then retired.

No new secondary accounts or internal account transfers are created.

---

## Navigation and Branding

The shared navigation includes an account/security status indicator.

Every page includes the global copyright footer:

```text
Copyright Pranav Hemahlathaa Harish and Hari Suhanth Karthikeyan, 2026.
```

Role badges are rendered without external assets:

* **Admin** — winged Patron-style crown emblem
* **Developer** — `</>` coding emblem

Dual-role accounts can display both badges.

---

## Future Hardening

Potential future improvements include:

* Multi-factor authentication
* Verified-email password reset
* Fraud/risk review
* Improved accessibility
* CSRF protection
* Trusted scheduled-job worker
* Proper database migration tooling
* Stronger production session/security configuration
* Production-grade logging and monitoring

---

## Smoke Tests

Run the built-in tests with:

```cmd
python -m unittest discover -s tests -v
```

---

## Disclaimer

**RUBO Banking / MiniBank Demo is a software demonstration project.**

It is not a real bank, financial institution, payment service, or banking platform.

**No real money is transferred.**
