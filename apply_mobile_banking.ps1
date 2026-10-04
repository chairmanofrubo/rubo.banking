$app = Get-Content "app.py" -Raw

# =========================================================
# 1. ADD TRANSFER PIN TO USER MODEL
# =========================================================

$oldUser = @'
    account_type = db.Column(
        db.String(20),
        default="standard",
        nullable=False,
    )

    is_enabled = db.Column(
'@

$newUser = @'
    account_type = db.Column(
        db.String(20),
        default="standard",
        nullable=False,
    )

    transfer_pin_hash = db.Column(
        db.String(255),
        nullable=True,
    )

    is_enabled = db.Column(
'@

if (-not $app.Contains($oldUser)) {
    throw "Could not find the User model insertion point."
}

$app = $app.Replace($oldUser, $newUser)


# =========================================================
# 2. ADD TRANSFER PIN METHODS
# =========================================================

$oldMethods = @'
    def check_password(self, password):
        return check_password_hash(
            self.password_hash,
            password,
        )

    @property
    def has_management_access(self):
'@

$newMethods = @'
    def check_password(self, password):
        return check_password_hash(
            self.password_hash,
            password,
        )

    def set_transfer_pin(self, pin):
        self.transfer_pin_hash = generate_password_hash(pin)

    def check_transfer_pin(self, pin):
        return bool(self.transfer_pin_hash) and check_password_hash(
            self.transfer_pin_hash,
            pin,
        )

    @property
    def has_management_access(self):
'@

if (-not $app.Contains($oldMethods)) {
    throw "Could not find password method insertion point."
}

$app = $app.Replace($oldMethods, $newMethods)


# =========================================================
# 3. ADD DATABASE MIGRATION
# =========================================================

$oldMigration = @'
    if "account_type" not in user_columns:
        db.session.execute(
            text(
                'ALTER TABLE "user" ADD COLUMN account_type '
                "VARCHAR(20) NOT NULL DEFAULT 'standard'"
            )
        )
        db.session.commit()
        db.session.execute(
            text(
                'UPDATE "user" SET account_type = \'admin\' '
                "WHERE is_admin = 1"
            )
        )
        db.session.commit()

    # Migrate legacy savings balances exactly once before retiring the table.
'@

$newMigration = @'
    if "account_type" not in user_columns:
        db.session.execute(
            text(
                'ALTER TABLE "user" ADD COLUMN account_type '
                "VARCHAR(20) NOT NULL DEFAULT 'standard'"
            )
        )
        db.session.commit()
        db.session.execute(
            text(
                'UPDATE "user" SET account_type = \'admin\' '
                "WHERE is_admin = 1"
            )
        )
        db.session.commit()

    if "transfer_pin_hash" not in user_columns:
        db.session.execute(
            text(
                'ALTER TABLE "user" ADD COLUMN transfer_pin_hash '
                "VARCHAR(255)"
            )
        )
        db.session.commit()

    # Migrate legacy savings balances exactly once before retiring the table.
'@

if (-not $app.Contains($oldMigration)) {
    throw "Could not find database migration insertion point."
}

$app = $app.Replace($oldMigration, $newMigration)


# =========================================================
# 4. REPLACE ACCOUNTS + TRANSFER ROUTES
# =========================================================

$startMarker = @'
# ACCOUNTS
# =========================================================
'@

$endMarker = @'
@app.route("/admin/transfer", methods=["POST"])
'@

$startIndex = $app.IndexOf($startMarker)
$endIndex = $app.IndexOf($endMarker)

if ($startIndex -lt 0 -or $endIndex -lt 0 -or $endIndex -le $startIndex) {
    throw "Could not find Accounts/Transfer route section."
}

$newRoutes = @'
# ACCOUNTS
# =========================================================

@app.route("/accounts", methods=["GET"])
@login_required
def accounts():
    return render_template(
        "accounts.html",
        transfer_pin_configured=bool(current_user.transfer_pin_hash),
    )


@app.route("/accounts/transfer-pin", methods=["POST"])
@login_required
def set_transfer_pin():
    current_pin = request.form.get("current_pin", "").strip()
    new_pin = request.form.get("new_pin", "").strip()
    confirm_pin = request.form.get("confirm_pin", "").strip()

    if not new_pin.isdigit() or len(new_pin) != 6:
        flash("Your Transfer PIN must be exactly 6 digits.", "error")
        return redirect(url_for("accounts"))

    if new_pin != confirm_pin:
        flash("The new Transfer PINs do not match.", "error")
        return redirect(url_for("accounts"))

    if current_user.transfer_pin_hash:
        if not current_pin or not current_user.check_transfer_pin(current_pin):
            flash("Your current Transfer PIN is incorrect.", "error")
            return redirect(url_for("accounts"))

        message = "Your Transfer PIN has been changed."
    else:
        message = "Your Transfer PIN has been created."

    current_user.set_transfer_pin(new_pin)
    db.session.commit()

    flash(message, "success")
    return redirect(url_for("accounts"))


# =========================================================
# USER-TO-USER TRANSFERS
# =========================================================

@app.route("/transfer", methods=["GET", "POST"])
@login_required
def transfer():
    if request.method == "POST":
        if not current_user.transfer_pin_hash:
            flash(
                "Set up your Transfer PIN in Accounts before making a transfer.",
                "error",
            )
            return redirect(url_for("accounts"))

        beneficiary_id = request.form.get("beneficiary_id", "").strip()
        receiver = None

        if beneficiary_id:
            try:
                beneficiary = Beneficiary.query.filter_by(
                    id=int(beneficiary_id),
                    owner_id=current_user.id,
                ).first()
            except (TypeError, ValueError):
                beneficiary = None

            if beneficiary:
                receiver = beneficiary.beneficiary

        receiver_username = request.form.get(
            "receiver_username",
            "",
        ).strip()

        if receiver is None:
            receiver = User.query.filter_by(
                username=receiver_username
            ).first()

        if not receiver or not receiver.is_enabled:
            flash("Recipient not found.", "error")
            return redirect(url_for("transfer"))

        if receiver.id == current_user.id:
            flash(
                "You cannot transfer to yourself.",
                "error",
            )
            return redirect(url_for("transfer"))

        try:
            amount = Decimal(
                request.form.get("amount", "")
            ).quantize(Decimal("0.01"))
        except (InvalidOperation, ValueError, TypeError):
            flash(
                "Enter a valid amount.",
                "error",
            )
            return redirect(url_for("transfer"))

        if amount <= 0:
            flash(
                "Amount must be greater than zero.",
                "error",
            )
            return redirect(url_for("transfer"))

        if amount > Decimal(current_user.balance):
            flash(
                "Insufficient checking balance.",
                "error",
            )
            return redirect(url_for("transfer"))

        note = request.form.get(
            "note",
            "",
        ).strip()[:200]

        duplicate_cutoff = datetime.now(timezone.utc) - timedelta(seconds=60)

        duplicate = Transaction.query.filter(
            Transaction.sender_id == current_user.id,
            Transaction.receiver_id == receiver.id,
            Transaction.amount == amount,
            Transaction.note == note,
            Transaction.created_at >= duplicate_cutoff,
            Transaction.status == "completed",
        ).first()

        if duplicate:
            flash(
                "A matching transfer was submitted recently.",
                "error",
            )
            return redirect(url_for("transfer"))

        session["pending_transfer"] = {
            "receiver_id": receiver.id,
            "amount": str(amount),
            "note": note,
        }

        return redirect(url_for("confirm_transfer"))

    return render_template(
        "transfer.html",
        beneficiaries=Beneficiary.query.filter_by(
            owner_id=current_user.id
        ).order_by(Beneficiary.nickname.asc()).all(),
    )


@app.route("/transfer/confirm", methods=["GET", "POST"])
@login_required
def confirm_transfer():
    pending = session.get("pending_transfer")

    if not pending:
        flash("There is no transfer waiting for confirmation.", "error")
        return redirect(url_for("transfer"))

    if not current_user.transfer_pin_hash:
        session.pop("pending_transfer", None)
        flash(
            "Set up your Transfer PIN in Accounts before making a transfer.",
            "error",
        )
        return redirect(url_for("accounts"))

    receiver = db.session.get(
        User,
        pending.get("receiver_id"),
    )

    if not receiver or not receiver.is_enabled:
        session.pop("pending_transfer", None)
        flash("The recipient is no longer available.", "error")
        return redirect(url_for("transfer"))

    try:
        amount = Decimal(
            str(pending.get("amount", "0"))
        ).quantize(Decimal("0.01"))
    except (InvalidOperation, ValueError, TypeError):
        session.pop("pending_transfer", None)
        flash("The pending transfer is invalid.", "error")
        return redirect(url_for("transfer"))

    if amount <= 0 or amount > Decimal(current_user.balance):
        session.pop("pending_transfer", None)
        flash("The transfer can no longer be completed.", "error")
        return redirect(url_for("transfer"))

    if request.method == "POST":
        transfer_pin = request.form.get(
            "transfer_pin",
            "",
        ).strip()

        if not transfer_pin.isdigit() or len(transfer_pin) != 6:
            flash(
                "Enter your 6-digit Transfer PIN.",
                "error",
            )
            return redirect(url_for("confirm_transfer"))

        if not current_user.check_transfer_pin(transfer_pin):
            flash(
                "Incorrect Transfer PIN. No money was transferred.",
                "error",
            )
            return redirect(url_for("confirm_transfer"))

        note = str(pending.get("note", ""))[:200]

        duplicate_cutoff = datetime.now(timezone.utc) - timedelta(seconds=60)

        duplicate = Transaction.query.filter(
            Transaction.sender_id == current_user.id,
            Transaction.receiver_id == receiver.id,
            Transaction.amount == amount,
            Transaction.note == note,
            Transaction.created_at >= duplicate_cutoff,
            Transaction.status == "completed",
        ).first()

        if duplicate:
            session.pop("pending_transfer", None)
            flash(
                "A matching transfer was submitted recently.",
                "error",
            )
            return redirect(url_for("transfer"))

        current_user.balance = (
            Decimal(current_user.balance) - amount
        )

        receiver.balance = (
            Decimal(receiver.balance) + amount
        )

        transaction = Transaction(
            sender_id=current_user.id,
            receiver_id=receiver.id,
            amount=amount,
            note=note,
        )

        db.session.add(transaction)
        db.session.flush()

        add_ledger_entries(transaction)

        create_notification(
            receiver.id,
            "Money received",
            f"{current_user.username} sent you {money(amount)}.",
        )

        db.session.commit()

        session.pop("pending_transfer", None)

        transaction_data = {
            "transaction_id": transaction.id,
            "sender_id": transaction.sender_id,
            "receiver_id": transaction.receiver_id,
            "amount": str(transaction.amount),
        }

        send_live_update(
            current_user.id,
            "transfer_completed",
            **transaction_data,
        )

        send_live_update(
            receiver.id,
            "money_received",
            **transaction_data,
        )

        return redirect(
            url_for(
                "transfer_receipt",
                transaction_id=transaction.id,
            )
        )

    return render_template(
        "transfer_confirm.html",
        receiver=receiver,
        amount=amount,
        note=pending.get("note", ""),
    )


'@

$app = $app.Substring(0, $startIndex) + $newRoutes + $app.Substring($endIndex)


# =========================================================
# 5. WRITE app.py
# =========================================================

Set-Content "app.py" $app -Encoding UTF8


# =========================================================
# 6. REPLACE ACCOUNTS TEMPLATE
# =========================================================

$accountsTemplate = @'
{% extends "base.html" %}

{% block title %}
Accounts | RUBO Banking
{% endblock %}

{% block content %}

<div class="page-heading">
    <div>
        <p class="page-label">ACCOUNT</p>
        <h1>My account</h1>
        <p>Manage your demo checking account and Transfer PIN.</p>
    </div>
</div>

<section class="account-balance-card">
    <span class="balance-label">AVAILABLE CHECKING BALANCE</span>
    <h2>{{ current_user.balance|money }}</h2>
    <p>Available for transfers to other RUBO demo accounts.</p>
</section>

<section class="professional-panel transfer-pin-card">
    <div class="panel-header">
        <div>
            <p class="page-label">SECURITY</p>
            <h2>Transfer PIN</h2>
            <p>
                Use your 6-digit Transfer PIN to authorize transfers.
                Your PIN is securely hashed and is never displayed.
            </p>
        </div>

        {% if transfer_pin_configured %}
        <span class="account-status">SET UP</span>
        {% else %}
        <span class="account-status account-status-warning">NOT SET</span>
        {% endif %}
    </div>

    {% if transfer_pin_configured %}
    <div class="pin-security-status">
        <strong>Transfer PIN is active</strong>
        <span>You will be asked for it before a transfer is completed.</span>
    </div>
    {% endif %}

    <form method="post"
          action="{{ url_for('set_transfer_pin') }}"
          class="professional-form transfer-pin-form">

        {% if transfer_pin_configured %}
        <div class="form-group">
            <label for="current_pin">Current Transfer PIN</label>
            <input
                id="current_pin"
                name="current_pin"
                type="password"
                inputmode="numeric"
                pattern="[0-9]{6}"
                maxlength="6"
                autocomplete="off"
                placeholder="••••••"
                required
            >
        </div>
        {% endif %}

        <div class="form-group">
            <label for="new_pin">
                {% if transfer_pin_configured %}
                New Transfer PIN
                {% else %}
                Create Transfer PIN
                {% endif %}
            </label>

            <input
                id="new_pin"
                name="new_pin"
                type="password"
                inputmode="numeric"
                pattern="[0-9]{6}"
                maxlength="6"
                autocomplete="new-password"
                placeholder="6 digits"
                required
            >
        </div>

        <div class="form-group">
            <label for="confirm_pin">Confirm Transfer PIN</label>

            <input
                id="confirm_pin"
                name="confirm_pin"
                type="password"
                inputmode="numeric"
                pattern="[0-9]{6}"
                maxlength="6"
                autocomplete="new-password"
                placeholder="Enter it again"
                required
            >
        </div>

        <button class="primary-bank-button" type="submit">
            {% if transfer_pin_configured %}
            Change Transfer PIN
            {% else %}
            Set Transfer PIN
            {% endif %}
        </button>
    </form>

    <div class="demo-security-box">
        DEMO SECURITY
        <span>
            This is a simulated banking system. No real bank accounts or
            real money are connected.
        </span>
    </div>
</section>

<section class="professional-panel">
    <div class="panel-header">
        <div>
            <h2>Account status</h2>
            <p>Your demo checking account is active.</p>
        </div>
        <span class="account-status">ACTIVE</span>
    </div>
</section>

{% endblock %}
'@

Set-Content "templates\accounts.html" $accountsTemplate -Encoding UTF8


# =========================================================
# 7. REPLACE TRANSFER TEMPLATE
# =========================================================

$transferTemplate = @'
{% extends "base.html" %}

{% block title %}
Transfer | RUBO Banking
{% endblock %}

{% block content %}

<div class="page-heading">
    <div>
        <p class="page-label">TRANSFER</p>
        <h1>Send money</h1>
        <p>Transfer demo funds securely to another RUBO account.</p>
    </div>
</div>

<div class="transfer-layout">
    <section class="professional-panel transfer-panel">
        <div class="panel-header">
            <div>
                <h2>New transfer</h2>
                <p>Enter the recipient and amount. You will confirm the transfer with your Transfer PIN.</p>
                <p>
                    <a href="{{ url_for('beneficiaries') }}">Manage beneficiaries</a>
                    ·
                    <a href="{{ url_for('scheduled_transfers') }}">Schedule a transfer</a>
                </p>
            </div>
        </div>

        <form method="post" class="professional-form">

            <div class="form-group">
                <label for="beneficiary_id">Saved beneficiary</label>

                <select id="beneficiary_id" name="beneficiary_id">
                    <option value="">Choose a saved beneficiary</option>

                    {% for item in beneficiaries %}
                    <option value="{{ item.id }}">
                        {{ item.nickname }} · @{{ item.beneficiary.username }}
                    </option>
                    {% endfor %}
                </select>
            </div>

            <div class="form-group">
                <label for="receiver_username">
                    Recipient username
                </label>

                <div class="input-prefix-wrapper">
                    <span>@</span>
                    <input
                        id="receiver_username"
                        name="receiver_username"
                        placeholder="username"
                    >
                </div>
            </div>

            <div class="form-group">
                <label for="amount">Amount</label>

                <div class="input-prefix-wrapper">
                    <span>$</span>
                    <input
                        id="amount"
                        name="amount"
                        type="number"
                        min="0.01"
                        step="0.01"
                        placeholder="0.00"
                        required
                    >
                </div>
            </div>

            <div class="form-group">
                <label for="note">Transfer note</label>

                <input
                    id="note"
                    name="note"
                    maxlength="200"
                    placeholder="Optional note"
                >
            </div>

            <button class="primary-bank-button" type="submit">
                Review transfer
            </button>
        </form>
    </section>

    <aside class="transfer-summary-card">
        <span class="summary-label">AVAILABLE BALANCE</span>

        <h2>{{ current_user.balance|money }}</h2>

        <div class="summary-divider"></div>

        <p>
            Your transfer will not be completed until you enter your
            Transfer PIN.
        </p>

        <div class="demo-security-box">
            TRANSFER SECURITY
            <span>6-digit Transfer PIN required before completion.</span>
        </div>
    </aside>
</div>

{% endblock %}
'@

Set-Content "templates\transfer.html" $transferTemplate -Encoding UTF8


# =========================================================
# 8. CREATE TRANSFER CONFIRMATION PAGE
# =========================================================

$confirmTemplate = @'
{% extends "base.html" %}

{% block title %}
Confirm Transfer | RUBO Banking
{% endblock %}

{% block content %}

<div class="pin-confirm-page">

    <section class="professional-panel pin-confirm-card">

        <div class="pin-lock-icon">●</div>

        <p class="page-label">TRANSFER SECURITY</p>

        <h1>Confirm transfer</h1>

        <p class="pin-confirm-description">
            Enter your 6-digit Transfer PIN to authorize this transfer.
        </p>

        <div class="pin-transfer-summary">

            <div>
                <span>Sending to</span>
                <strong>@{{ receiver.username }}</strong>
            </div>

            <div>
                <span>Amount</span>
                <strong>{{ amount|money }}</strong>
            </div>

            {% if note %}
            <div>
                <span>Note</span>
                <strong>{{ note }}</strong>
            </div>
            {% endif %}

        </div>

        <form method="post" class="professional-form pin-entry-form">

            <div class="form-group">
                <label for="transfer_pin">Transfer PIN</label>

                <input
                    id="transfer_pin"
                    name="transfer_pin"
                    class="transfer-pin-input"
                    type="password"
                    inputmode="numeric"
                    pattern="[0-9]{6}"
                    maxlength="6"
                    autocomplete="off"
                    placeholder="••••••"
                    autofocus
                    required
                >

                <small>
                    Your PIN is never displayed or stored as plain text.
                </small>
            </div>

            <button class="primary-bank-button" type="submit">
                Confirm and transfer
            </button>

            <a
                class="secondary-bank-button"
                href="{{ url_for('transfer') }}"
            >
                Cancel
            </a>

        </form>

        <div class="demo-security-box">
            DEMO BANK
            <span>
                No real money will be transferred. This is a simulated
                banking environment.
            </span>
        </div>

    </section>

</div>

{% endblock %}
'@

Set-Content "templates\transfer_confirm.html" $confirmTemplate -Encoding UTF8


# =========================================================
# 9. ADD MOBILE + PIN CSS
# =========================================================

$css = @'

/* =========================================================
   MOBILE BANKING + TRANSFER PIN
   ========================================================= */

.transfer-pin-card {
    max-width: 720px;
}

.transfer-pin-form {
    max-width: 520px;
}

.pin-security-status {
    display: flex;
    flex-direction: column;
    gap: 4px;
    padding: 14px 16px;
    margin: 20px 0;
    border: 1px solid var(--border);
    border-radius: 12px;
    background: var(--background);
}

.pin-security-status span {
    color: var(--muted);
    font-size: 14px;
}

.account-status-warning {
    background: #fff4d6;
    color: #8a6200;
}

.pin-confirm-page {
    width: 100%;
    display: flex;
    justify-content: center;
}

.pin-confirm-card {
    width: 100%;
    max-width: 520px;
    text-align: center;
}

.pin-lock-icon {
    width: 58px;
    height: 58px;
    margin: 0 auto 18px;
    border-radius: 50%;
    display: flex;
    align-items: center;
    justify-content: center;
    background: var(--primary);
    color: white;
    font-size: 18px;
}

.pin-confirm-description {
    color: var(--muted);
    max-width: 420px;
    margin: 0 auto 24px;
}

.pin-transfer-summary {
    display: flex;
    flex-direction: column;
    gap: 14px;
    text-align: left;
    padding: 18px;
    margin: 24px 0;
    border: 1px solid var(--border);
    border-radius: 14px;
    background: var(--background);
}

.pin-transfer-summary div {
    display: flex;
    justify-content: space-between;
    gap: 20px;
}

.pin-transfer-summary span {
    color: var(--muted);
}

.pin-transfer-summary strong {
    text-align: right;
    word-break: break-word;
}

.pin-entry-form {
    max-width: 380px;
    margin: 0 auto;
}

.transfer-pin-input {
    text-align: center;
    letter-spacing: 0.45em;
    font-size: 24px;
    font-weight: 700;
}

.pin-entry-form small {
    display: block;
    margin-top: 8px;
    color: var(--muted);
}

.secondary-bank-button {
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 46px;
    padding: 10px 16px;
    border: 1px solid var(--border);
    border-radius: 10px;
    background: transparent;
    color: var(--text);
    text-decoration: none;
    font-weight: 600;
}

.secondary-bank-button:hover {
    background: var(--background);
}

@media (max-width: 600px) {
    .main-content {
        padding: 16px;
    }

    .page-heading {
        margin-bottom: 18px;
    }

    .page-heading h1 {
        font-size: 25px;
    }

    .account-balance-card {
        padding: 20px;
        border-radius: 18px;
    }

    .account-balance-card h2 {
        font-size: 32px;
    }

    .professional-panel,
    .transfer-summary-card {
        border-radius: 16px;
    }

    .transfer-layout {
        gap: 14px;
    }

    .transfer-panel {
        padding: 18px;
    }

    .transfer-summary-card {
        padding: 18px;
    }

    .professional-form input,
    .professional-form select,
    .professional-form button,
    .primary-bank-button,
    .secondary-bank-button {
        min-height: 50px;
        font-size: 16px;
    }

    .pin-confirm-card {
        padding: 22px 18px;
    }

    .pin-transfer-summary div {
        align-items: flex-start;
        flex-direction: column;
        gap: 4px;
    }

    .pin-transfer-summary strong {
        text-align: left;
    }

    .transfer-pin-input {
        font-size: 26px;
        letter-spacing: 0.35em;
    }
}
'@

Add-Content "static\style.css" $css -Encoding UTF8


Write-Host ""
Write-Host "============================================"
Write-Host " RUBO mobile banking changes applied!"
Write-Host "============================================"
Write-Host ""
Write-Host "Files changed:"
Write-Host "  app.py"
Write-Host "  templates\accounts.html"
Write-Host "  templates\transfer.html"
Write-Host "  templates\transfer_confirm.html"
Write-Host "  static\style.css"
Write-Host ""
Write-Host "Next: run the app and test the Transfer PIN."