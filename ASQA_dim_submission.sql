/* ==========================================================================
   dim_submission (source select) and the slimmed fact_submission
   SOURCE TABLES ONLY. Business keys, no gold joins, no -1 handling.

   WHY THE SPLIT
     dim_submission    : what a submission IS (type, method, origin, status, approved,
                         reference numbers). Descriptive only. No RTO key, no date keys.
                         Every fact relates to it by submission_sk.
     fact_submission   : what HAPPENED (one row per submission with its RTO and dates,
                         plus a count). Same grain as the dim, so it is 1:1.
     Keeping rto and dates OUT of dim_submission is what stops a second path from
     dim_rto / dim_date to the child facts in the semantic model.

   LABELS
     Origin and status labels come from the Dataverse metadata tables that Synapse Link
     exports (GlobalOptionsetMetadata, StatusMetadata, StateMetadata). OUTER APPLY TOP 1
     is used so a duplicate metadata row can never multiply submissions.
     StatusMetadata and StateMetadata column names match your export.
     GlobalOptionsetMetadata column names are from the Synapse Link docs, so run
     SELECT TOP 5 * FROM dbo.GlobalOptionsetMetadata to confirm them.

   NOT RUN. Syntax-check before you trust it.
   ========================================================================== */


/* ---------- dim_submission ----------
   Grain: one row per registration submission (same rows as fact_submission).
   Gold adds: submission_sk (identity), -1 Unknown member, and swaps the *_bk below
   for *_sk (dim_submission_type, dim_submission_method, dim_contact). */
SELECT
    s.Id                                AS submission_bk,
    s.asqa_regsubid                     AS regsubid,
    s.asqa_requestreferenceid           AS request_reference_id,
    s.asqa_registrationsubmissiontype   AS type_bk,              -- gold: type_sk, the family mapping lives in dim_submission_type
    s.asqa_submissionmethod             AS submission_method_bk, -- gold: submission_method_sk
    s.asqa_submittedby                  AS submitted_by_bk,      -- gold: submitted_by_sk (key only)
    s.asqa_origin                       AS origin_code,
    og.LocalizedLabel                   AS origin_label,         -- External / Internal / Migrated / System
    s.statecode                         AS state_code,
    ste.LocalizedLabel                  AS state_label,          -- Active / Inactive
    s.statuscode                        AS status_code,
    sts.LocalizedLabel                  AS status_label,         -- Submitted, Closed - approved, Closed - lapsed ...
    s.asqa_approved                     AS is_approved
FROM dbo.asqa_registrationsubmission s
OUTER APPLY (
    SELECT TOP 1 g.LocalizedLabel
    FROM dbo.GlobalOptionsetMetadata g
    WHERE g.EntityName    = 'asqa_registrationsubmission'
      AND g.OptionSetName = 'asqa_origin'
      AND g.[Option]      = s.asqa_origin
      AND g.LocalizedLabelLanguageCode = 1033
) og
OUTER APPLY (
    SELECT TOP 1 m.LocalizedLabel
    FROM dbo.StatusMetadata m
    WHERE m.EntityName = 'asqa_registrationsubmission'
      AND m.Status     = s.statuscode
      AND m.LocalizedLabelLanguageCode = 1033
) sts
OUTER APPLY (
    SELECT TOP 1 m.LocalizedLabel
    FROM dbo.StateMetadata m
    WHERE m.EntityName = 'asqa_registrationsubmission'
      AND m.State      = s.statecode
      AND m.LocalizedLabelLanguageCode = 1033
) ste
WHERE s.IsDelete IS NULL;


/* ---------- fact_submission (slimmed) ----------
   Grain: one row per registration submission.
   Descriptive columns moved to dim_submission. What stays: the RTO, the dates and a count.
   Gold adds: submission_sk (the same value as dim_submission.submission_sk, so the join is 1:1),
   rto_bk -> rto_sk, *_date -> *_date_sk. */
SELECT
    s.Id                        AS submission_bk,
    s.asqa_account              AS rto_bk,
    s.asqa_submitteddate        AS submitted_date,
    s.createdon                 AS created_date,
    s.modifiedon                AS modified_date,
    1                           AS submission_count
FROM dbo.asqa_registrationsubmission s
WHERE s.IsDelete IS NULL;
