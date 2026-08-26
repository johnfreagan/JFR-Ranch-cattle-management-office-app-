# Field App — User Guide

**Who this is for:** cowboys and anyone recording work in the pasture.

**The app:**
<https://johnfreagan.github.io/JFR-Ranch-cattle-management-office-app-/field-app/>

**Last verified against the app:** 2026-08-26 (field app build v12).

> **Everything in here is live.** Personal logins, the office seeing your
> records directly, and records coming back marked **sent back** all went live
> on 2026-08-25. Nothing in this guide is a promise any more — it describes the
> app as it works today.

---

## 1. Install it on your phone

Do this once. It puts the app on your home screen and lets it run without
signal.

**iPhone (Safari — must be Safari, not Chrome):**
1. Open the link above.
2. Tap the **Share** button (square with an arrow).
3. Scroll down, tap **Add to Home Screen**, then **Add**.

**Android (Chrome):**
1. Open the link above.
2. Tap the **⋮** menu.
3. Tap **Install app** or **Add to Home screen**.

You will get a blue longhorn icon labeled **Beta Tracker**. Open the app from
that icon from now on, not from the browser.

> **If you already had the old app installed** (from the older link), open
> that one once while you have signal. It will clear itself out and send you
> here. Nothing you recorded is lost — both versions share the same storage on
> your phone.

---

## 2. Signing in

Each person has their own login. Your name fills in automatically from your
account, and your name and role show at the top of the screen once you are in
— so the office always knows who did the work without anybody typing it.

**Getting your account.** John creates it. You will get either an email invite
with a link to set your own password, or a password from him directly. You do
not sign yourself up.

**Your first sign-in.**
1. Open the app.
2. Enter your **email** and **password**.
3. Tap **Sign in**.

You stay signed in. The app will not ask again unless you sign out or go a
long stretch without opening it. **Sign in once while you have signal** — the
first sign-in needs a connection.

**If it says your account is not active yet:** John has created your login but
has not switched it on. Text him. Nothing you do in the app will fix it.

**If you forget your password:** text John. He resets it. There is no
"forgot password" link in the app, and there will not be one until the ranch
runs its own mail — so do not wait on an email that is not coming.

**Signing out.** Only sign out if you are handing the phone to somebody else.
Signing out clears the app, and **anything still waiting to sync will be
lost**. Check that the sync badge is clear first (see §4).

**One person per phone.** Do not share a login. Every record is stamped with
who saved it — that is how a treatment gets traced back to the person who gave
it, and how the office knows who to ask when something looks off.

---

## 3. Recording work

Three tabs across the top: **🩺 Doctoring**, **🚚 Moves**, and **📖 History**.

### A doctoring record

1. **Crew Member** — already filled in from your account. Leave it alone
   unless you are recording work somebody else did.
2. **Tag #** — type the tag number, or use the two buttons beside it:
   - **↺** repeats the last tag you saved (same animal needs another action, or
     you are correcting a save).
   - **NT** is a no-tag entry. It auto-numbers the animal NT1, NT2, NT3, so
     untagged cattle still get tracked.
3. **Date & Time** — defaults to now. Change it if you are catching up.
4. **Ranch**, **Pasture**, **Lot** — dropdowns. Pasture only unlocks once you
   pick a ranch.
5. **Action** — Receiving, First Pull EX, Second Pull RES, Pinkeye, Footrot
   Dart, Dead, or Other.
6. **Medications and dose** — up to three, with the cc given for each. Picking
   an action auto-fills the medications from its protocol; change them if what
   you actually gave was different.
7. **Notes** — anything the office should know.
8. Tap **Save Record**.

**The lock buttons.** The 🔓 next to Ranch, Pasture, Lot, and Action. Tap it to
lock that field so it stays filled in across saves instead of resetting.
Working one pasture all morning? Lock ranch, pasture, and lot, and each animal
costs you a tag and an action. Tap again to unlock.

Locking **Action** still re-fills the medications from the protocol every time,
so a locked action does not mean stale meds.

**Tag History.** Tap a tag number to see everything recorded against that
animal — what it has already been given, and when. Check it before you treat.

### A move

Switch to **🚚 Moves**: who, from ranch/pasture, to ranch/pasture, head count,
date, notes. Tap **Save Move**.

The office has to attach a move to a lot before it counts, so put the lot in
the notes if you know it. It saves them a phone call.

### Fixing a mistake

**📖 History** → find the row → **Edit** or **Del**. History shows today and
yesterday. Fix it the same day if you can; once the office has taken a record
into the books it is out of your hands, so text them instead.

---

## 4. Working without signal

The app is built for the pasture. **Everything saves to your phone first.** No
bars, no problem — keep recording.

**Uploads happen by themselves.** The app retries whenever you come back on
signal, whenever you open it, and about once a minute while it is open. You do
not have to push anything.

**Watch the badge** next to the sync button at the top:

| Badge | Means |
|---|---|
| *(nothing)* | You are online and everything is uploaded. Good. |
| `⚠ Offline` | No signal. Keep recording — it is all being kept. |
| `⚠ Offline · 3 pending` | No signal, 3 records waiting on your phone. |
| A number, online | Uploading now, or retrying. It should clear on its own. |

You will get an **☁️ All records synced** message when the last one goes up.

**Two rules:**

- **Get back on signal the same day** and check the badge has cleared. Records
  sitting on your phone are not in the books and nobody else can see them.
- **Do not delete the app or clear your browser data while the badge shows a
  number.** Those records live only on your phone until they upload.

**🔄 Pull Cloud History** is the other direction — it *downloads* the latest
records, ranches, pastures, lots, medications, and protocols. Tap it when a
pasture or lot is missing from your dropdowns, or when you want to see what
somebody else recorded. It merges with anything you have saved offline; it
does not overwrite your work.

---

## 5. Trouble

| What you see | What to do |
|---|---|
| App will not open, blank screen | Close it fully and reopen. Still blank — open the link in your browser while on signal, which pulls a fresh copy. |
| Badge stuck on a number while you have bars | You are not really online. Try mobile data instead of weak Wi-Fi. If it still sticks, text John — **do not** delete the app. |
| A ranch, pasture, or lot is missing | Tap **🔄 Pull Cloud History** first. If it is still missing, pick the closest match, say so in the notes, and text the office. Do not improvise a name. |
| Wrong tag or wrong med saved | **📖 History** → **Edit**. |
| "Not active yet" at sign-in | John needs to switch your account on. Text him. Nothing you do in the app will fix it. |
| Forgot password | Text John for a reset. There is no "forgot password" link. |
| A record comes back marked **sent back** | The office could not use it. Their note says why. Fix it and save again — do not start a new record. |

There is a **📘 Help** button at the bottom with a 30-second quickstart, and a
troubleshoot button beside it.

---

## 6. What comes next

**The three things this section used to promise are all live now**, as of
2026-08-25:

1. ~~Your own login~~ — done. §2 above describes how it works.
2. ~~The office sees your records directly~~ — done. Nothing you save is
   re-keyed by hand any more. It lands in an office review queue and the office
   approves it into the books.
3. ~~You will see rejections~~ — done. If the office sends a record back —
   wrong lot, a medication they cannot read — it shows in your app marked
   **sent back**, with their note, for you to fix rather than redo.

Nothing about how you record changed, exactly as promised: the lock buttons,
the offline queue and the history tab all work the way they always did.

**Still to come:** the daily report sending itself to the office each evening
instead of somebody opening the app to send it. Nothing about your side
changes when that lands.
