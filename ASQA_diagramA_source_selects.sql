/* ==========================================================================
   ASQA source selects for ER Diagram A
   dim_submission, fact_submission, fact_renewal, fact_ownership_change,
   fact_ownership_share, fact_measurement_period

   SOURCE TABLES ONLY. dbo.* only. No gold tables, no surrogate keys, no -1 handling.

   Each query returns the diagram's columns with business keys (*_bk) where gold will
   later hold surrogate keys (*_sk), and plain dates where gold will later hold date keys.

   WHAT HAPPENS LATER, IN GOLD (not here)
     *_bk   -> *_sk       look the bk up in the matching dim
     *_date -> *_date_sk  yyyymmdd int, -1 when NULL
     NULL / missing lookup -> -1 (the Unknown member)
     submission_bk -> submission_sk via dim_submission (NOT fact_submission)
     The fact's own surrogate key (renewal_sk, owner_sk ...) is generated on insert.
     fact_submission.submission_sk takes the same value as dim_submission.submission_sk.

   WHAT IS DONE HERE
     - IsDelete tombstones removed.
     - On the child facts the submission is LEFT JOINed on, so submission_bk is NULL
       when no submission points at the child (gold turns that into -1).
     - Yes/No CHOICE columns decoded (100000000 = Yes, 100000001 = No).
     - Text-stored numbers cast with TRY_CAST.
     - Column names are the diagram names.

   NOT RUN. Syntax-check before you trust it.
   On each child query compare COUNT(*) with COUNT(DISTINCT <child>_bk). More rows than
   distinct children means two submissions point at the same child.
   ========================================================================== */


/* ---------- 1. dim_submission ----------
   Grain: one row per registration submission.
   Source: dbo.asqa_registrationsubmission plus the Dataverse metadata tables for labels.
   OUTER APPLY TOP 1 so a duplicate metadata row can never multiply submissions.
   StatusMetadata and StateMetadata column names match your export.
   GlobalOptionsetMetadata column names come from the Synapse Link docs: run
   SELECT TOP 5 * FROM dbo.GlobalOptionsetMetadata to confirm them. */
SELECT
    s.Id                                AS submission_bk,
    s.asqa_regsubid                     AS regsubid,
    s.asqa_requestreferenceid           AS request_reference_id,
    s.asqa_registrationsubmissiontype   AS type_bk,              -- gold: type_sk
    s.asqa_submissionmethod             AS submission_method_bk, -- gold: submission_method_sk
    s.asqa_submittedby                  AS submitted_by_bk,      -- gold: submitted_by_sk
    s.asqa_origin                       AS origin_code,
    og.LocalizedLabel                   AS origin_label,         -- External, Internal, Migrated, System
    s.statecode                         AS state_code,
    ste.LocalizedLabel                  AS state_label,
    s.statuscode                        AS status_code,
    sts.LocalizedLabel                  AS status_label,         -- carries the outcome, e.g. Closed - approved
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


/* ---------- 2. fact_submission ----------
   Grain: one row per registration submission (1:1 with dim_submission).
   Source: dbo.asqa_registrationsubmission only.
   Holds the RTO, the dates and a count. Descriptive columns live in dim_submission. */
SELECT
    s.Id                        AS submission_bk,
    s.asqa_account              AS rto_bk,
    s.asqa_submitteddate        AS submitted_date,
    s.createdon                 AS created_date,
    s.modifiedon                AS modified_date,
    1                           AS submission_count
FROM dbo.asqa_registrationsubmission s
WHERE s.IsDelete IS NULL;


/* ---------- 3. fact_renewal ----------
   Grain: one row per renewal record.
   Source: dbo.asqa_rtorenewal, submission LEFT JOINed. */
SELECT
    o.Id                                    AS renewal_bk,
    s.Id                                    AS submission_bk,    -- NULL = no submission points at this renewal
    o.asqa_account                          AS rto_bk,
    o.statecode                             AS state_code,
    o.statuscode                            AS status_code,      -- 1 Active, 100000001 Closed, 100000002 Submitted
    o.asqa_renewaltype                      AS renewal_type_code,
    o.asqa_typeofregistrationforrenewal     AS registration_type_code,   -- 0 NVR, 1 CRICOS, 2 both
    CAST(CASE o.asqa_renewalsubmitted WHEN 100000000 THEN 1 WHEN 100000001 THEN 0 END AS bit) AS is_renewal_submitted,
    o.asqa_setrenewalduedate                AS renewal_due_date,
    o.createdon                             AS created_date
FROM dbo.asqa_rtorenewal o
LEFT JOIN dbo.asqa_registrationsubmission s
       ON s.asqa_rtorenewal = o.Id
      AND s.IsDelete IS NULL
WHERE o.IsDelete IS NULL;


/* ---------- 4. fact_ownership_change ----------
   Grain: one row per ownership change record.
   Source: dbo.asqa_rtoownership, submission LEFT JOINed.
   submission_bk NULL = the change did not come through a submission. */
SELECT
    o.Id                                            AS ownership_change_bk,
    s.Id                                            AS submission_bk,
    o.asqa_accountid                                AS rto_bk,
    o.statecode                                     AS state_code,
    o.statuscode                                    AS status_code,
    o.asqa_ownershipstatus                          AS ownership_status_code,      -- 100000000 Active, 100000001 Expired
    o.asqa_totalpercentageofshares                  AS total_percentage_of_shares,
    TRY_CAST(o.asqa_noofenrolledstudents AS int)    AS enrolled_students,          -- text in source
    TRY_CAST(o.asqa_noofstudentpriortochange AS int) AS students_prior_to_change,  -- text in source
    CAST(CASE o.asqa_has50percentagesharechanged WHEN 100000000 THEN 1 WHEN 100000001 THEN 0 END AS bit) AS has_50pct_share_changed,
    CAST(CASE o.asqa_changeofownershipinfuture   WHEN 100000000 THEN 1 WHEN 100000001 THEN 0 END AS bit) AS is_future_change,
    o.asqa_dateofeffect                             AS effective_date,
    o.asqa_dateoflastdeliveryoftraining             AS last_delivery_date,
    o.createdon                                     AS created_date
FROM dbo.asqa_rtoownership o
LEFT JOIN dbo.asqa_registrationsubmission s
       ON s.asqa_rtoownership = o.Id
      AND s.IsDelete IS NULL
WHERE o.IsDelete IS NULL;
-- Check: a non-NULL source text that comes back NULL after TRY_CAST is a non-numeric value.


/* ---------- 5. fact_ownership_share ----------
   Grain: one row per owner per ownership change.
   Source: dbo.asqa_rtoowner. TWO hops to the submission: the submission points at the
   ownership CHANGE, not the owner row, so owner -> change -> submission.
   ownership_change_bk is a plain column for SQL joins, not a semantic-model relationship. */
SELECT
    o.Id                                AS owner_bk,
    oc.Id                               AS ownership_change_bk,
    s.Id                                AS submission_bk,
    o.asqa_rtoaccount                   AS rto_bk,
    o.asqa_companyid                    AS owner_company_bk,        -- gold: owner_company_sk
    o.asqa_person                       AS owner_person_bk,         -- gold: owner_person_sk, restricted dim
    o.statecode                         AS state_code,
    o.statuscode                        AS status_code,
    o.asqa_ownertype                    AS owner_type_code,         -- 100000000 Organisation, 100000001 Person
    CAST(CASE o.asqa_isthisanaustralianorganisation WHEN 100000001 THEN 1 WHEN 100000002 THEN 0 END AS bit) AS is_australian_org,  -- 100000000 is '---', left NULL
    o.asqa_percentageofshares           AS percentage_of_shares,
    o.asqa_newpercentageofshares        AS new_percentage_of_shares,
    o.asqa_dateofeffect                 AS date_of_effect,
    o.createdon                         AS created_date
FROM dbo.asqa_rtoowner o
LEFT JOIN dbo.asqa_rtoownership oc
       ON oc.Id = o.asqa_rtoownership
      AND oc.IsDelete IS NULL
LEFT JOIN dbo.asqa_registrationsubmission s
       ON s.asqa_rtoownership = oc.Id
      AND s.IsDelete IS NULL
WHERE o.IsDelete IS NULL;


/* ---------- 6. fact_measurement_period ----------
   Grain: one row per lapse or extension record.
   Source: dbo.asqa_rtolapsing UNION ALL dbo.asqa_rtoextendmeasurementperiod.
   lapse_type_code: 80000000 Lapsing, 80000001 Extended measurement period.
   Extension-table rows are set to 80000001 so the union has one type column.
   Columns one table lacks are NULL.
   is_extension_in_effect: meaning still unconfirmed (BA question). */
SELECT
    l.Id                                                AS period_bk,
    'LAPSING'                                           AS period_source,
    s.Id                                                AS submission_bk,
    l.asqa_rtoaccount                                   AS rto_bk,
    l.statecode                                         AS state_code,
    l.statuscode                                        AS status_code,
    l.asqa_origin                                       AS origin_code,
    l.asqa_type                                         AS lapse_type_code,
    l.asqa_isanextensiontomeasurementperiodineffecty    AS is_extension_in_effect,
    l.asqa_whichregistrationareyourequestinganextension AS registration_type_code,
    l.asqa_measurementperiodstartdate                   AS measurement_period_start_date,
    l.asqa_measurementperiodenddate                     AS measurement_period_end_date,
    l.asqa_extensionstartdate                           AS extension_start_date,
    l.asqa_extensionenddate                             AS extension_end_date,
    l.asqa_reqedextensionstartdate                      AS requested_extension_start_date,
    l.asqa_requestedextensionenddate                    AS requested_extension_end_date,
    l.asqa_nildeliverystartdate                         AS nil_delivery_start_date,
    l.asqa_nildeliveryenddate                           AS nil_delivery_end_date,
    l.asqa_lastdateofdelivery                           AS last_delivery_date,
    l.createdon                                         AS created_date
FROM dbo.asqa_rtolapsing l
LEFT JOIN dbo.asqa_registrationsubmission s
       ON s.asqa_rtolapsing = l.Id
      AND s.IsDelete IS NULL
WHERE l.IsDelete IS NULL

UNION ALL

SELECT
    e.Id,
    'EXTENSION',
    s.Id,
    e.asqa_account,
    e.statecode,
    e.statuscode,
    CAST(NULL AS bigint),
    CAST(80000001 AS bigint),
    CAST(NULL AS bit),
    e.asqa_requestisfor,
    CAST(NULL AS datetime2),
    CAST(NULL AS datetime2),
    e.asqa_periodextensiondatefrom,
    e.asqa_periodextensiondateto,
    CAST(NULL AS datetime2),
    CAST(NULL AS datetime2),
    e.asqa_nildeliverydatefrom,
    e.asqa_nildeliverydateto,
    CAST(NULL AS datetime2),
    e.createdon
FROM dbo.asqa_rtoextendmeasurementperiod e
LEFT JOIN dbo.asqa_registrationsubmission s
       ON s.asqa_rtoextendmeasurementperiod = e.Id
      AND s.IsDelete IS NULL
WHERE e.IsDelete IS NULL;
