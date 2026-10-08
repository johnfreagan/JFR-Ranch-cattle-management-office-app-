# Cowork morning intake: feed report and medicine invoices

The Cowork scheduled task that stages the office app's emailed inputs every
morning. It replaces the prompt of the existing PB feed task (which has staged
the PB report daily at about 5:45 am CT since 2026-09-25) so that one task
reads both. Written 2026-10-08.

John, 2026-10-08: "Let's leave the routine as a cowork right now that fetch
both med invoices (not just bar j) and the feed email."

What it does and does not do:

- It **stages**. It never approves, posts, rejects or edits anything. John
  reviews in Approvals > Feed and Approvals > Meds.
- **The database reads the email.** The task hands over the plain-text body
  verbatim and the database parses it (`stage_pb_report`,
  `stage_med_invoice`). The model never does the arithmetic and never retypes
  a number into a staging call.
- It runs every morning **whether or not there is anything to find**, and
  says so.
- Staging is idempotent. The same PB message re-staged is a no-op; the same
  invoice (vendor + number) stages once. So it looks back 3 days on purpose:
  a missed morning or a weekend is caught the next run.
- **Only Bar J can be staged today**, because only Bar J has a parser
  (`med_parse_barj_invoice`). Any other medicine invoice (Double T, Agri Tech,
  anyone else) is reported for John with a paste block for the Purchases
  screen (the paste contract in `medicine-inventory-fifo-plan.md`). Double T
  sends its invoices as PDF attachments with no text in the body, so even a
  parser would need the PDF read first.
- It runs through the Supabase connector (project `xpfmebdzcxorvwikfvtj`).
  The publishable key cannot call these functions (anon has no EXECUTE).

PB's report arrives at about 11:00 pm CT the night before
(support@cattlekrush.com, "Your daily delivery report ..."), so a 5:45 am run
always has it.

## The task prompt (paste as is)

```
Morning intake for the JFR Ranch office app. Run every morning, even if there
is nothing to find. Use the Gmail connector and the Supabase connector
(project xpfmebdzcxorvwikfvtj). You STAGE only: never approve, post, reject,
edit or delete anything in the database. Never retype, summarize or "clean
up" an email before handing it over: the database reads it.

1. FEED (PB delivery report)
   Search Gmail: from:support@cattlekrush.com "daily delivery report" newer_than:3d
   For each message, get the plain-text body and run:
     select stage_pb_report('<gmail message id>', $body$<plain-text body, verbatim>$body$);
   Report the result per message exactly as returned (report date, problems).

2. MEDICINE INVOICES, BAR J (staged into Approvals > Meds)
   Search Gmail: subject:"Bar J Invoice" newer_than:3d
   For each message (Lauren's forward or a direct copy), get the plain-text
   body and run:
     select stage_med_invoice('<gmail message id>', $body$<plain-text body, verbatim>$body$);
   Report one line per invoice: staged (invoice #, total, any problems),
   already staged / posted, or the error exactly as returned.

3. MEDICINE INVOICES, ANY OTHER VENDOR (not staged; John enters them)
   Search Gmail for medicine or vet-supply invoices from anyone other than
   Bar J in the last 3 days, for example:
     (invoice OR receipt) (vet OR veterinary OR "animal health" OR "Double T" OR "Agri Tech") newer_than:3d -subject:"Bar J Invoice" -from:me
   Skip anything that is not a medicine/vet-supply invoice (feed, fuel,
   statements, marketing). For each real one, read it (including a PDF
   attachment) and give John a paste block for Inventory > Meds > Purchases >
   New purchase: one header line "Vendor<TAB>YYYY-MM-DD<TAB>Invoice#", then one
   line per product "Name<TAB>bottles<TAB>price per bottle", then the invoice
   total and any freight on its own line. Copy the numbers off the invoice;
   do not compute or adjust them. If you are not sure it is a medicine
   invoice, list it as "not sure" with the sender and subject.

4. REPORT (short, in this order)
   Feed: <date> staged / already staged / error, problems if any.
   Bar J: one line per invoice, or "no new Bar J invoices".
   Other med invoices: paste blocks, or "none".
   Any connector or database error, quoted exactly. Never say "nothing new"
   if a search or a call failed.
```

## Changes elsewhere

- The 4am triage stays as it is. A Bar J invoice is no longer a REPLY item:
  it is in Approvals > Meds. (That is a change to the triage prompt, which
  John makes in Cowork.)
- When another vendor sends often enough to matter, it gets its own parser
  migration and moves from step 3 to step 2.
