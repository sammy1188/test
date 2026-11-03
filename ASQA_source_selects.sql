/* ==========================================================================
   ASQA source selects for the facts split out of asqa_registrationsubmission
   SOURCE TABLES ONLY. No gold tables, no surrogate keys, no -1 handling.

   WHAT THIS IS
     The extract step. Each query reads the dbo.* source tables and returns one row
     per fact row, with business keys (*_bk) where gold will later hold surrogate
     keys (*_sk) and plain dates where gold will later hold date keys.

   WHAT HAPPENS LATER, IN GOLD (not here)
     *_bk  -> *_sk   by looking the bk up in the matching dim (rto_bk in dim_rto, etc.)
     *_date -> *_date_sk   (yyyymmdd int, -1 when NULL)
     NULL / missing lookup -> -1 (the Unknown member)
     The fact's own surrogate key (submission_sk, renewal_sk ...) is generated on insert.
     The earlier file ASQA_fact_selects.sql shows that second step.

   WHAT IS DONE HERE
     - IsDelete tombstones removed.
     - The submission is LEFT JOINed on, so submission_bk is NULL when none exists.
     - Yes/No CHOICE columns decoded (100000000 = Yes, 100000001 = No).
     - Text-stored numbers cast with TRY_CAST.
     - Column names are the gold names, so the next step is a straight swap.

   NOT RUN. Syntax-check before you trust it.
   Run the rows vs COUNT(DISTINCT <child>_bk) check on each query. More rows than
   distinct children means two submissions point at the same child.
   ========================================================================== */


/* ---------- 1. fact_submission ----------
   Grain: one row per registration submission.
   Source: dbo.asqa_registrationsubmission only. */
SELECT
    s.Id                                AS submission_bk,
    s.asqa_regsubid                     AS regsubid,
    s.asqa_requestreferenceid           AS request_reference_id,
    s.asqa_registrationsubmissiontype   AS type_bk,              -- gold: type_sk  via dim_submission_type
    s.asqa_account                      AS rto_bk,               -- gold: rto_sk   via dim_rto
    s.asqa_submittedby                  AS submitted_by_bk,      -- gold: submitted_by_sk
    s.asqa_submissionmethod             AS submission_method_bk, -- gold: submission_method_sk
    s.asqa_origin                       AS origin_code,          -- 100000000 External, 1 Internal, 2 Migrated, 3 System
    s.statecode                         AS state_code,
    s.statuscode                        AS status_code,          -- carries the outcome (Closed - approved, rejected, lapsed ...)
    s.asqa_submitteddate                AS submitted_date,
    s.asqa_approved                     AS is_approved,
    s.createdon                         AS created_date,
    s.modifiedon                        AS modified_date
FROM dbo.asqa_registrationsubmission s
WHERE s.IsDelete IS NULL;


/* ---------- 2. fact_renewal ----------
   Grain: one row per renewal record.
   Source: dbo.asqa_rtorenewal, submission LEFT JOINed. */
SELECT
    o.Id                                    AS renewal_bk,
    s.Id                                    AS submission_bk,    -- NULL = no submission points at this renewal
    o.asqa_account                          AS rto_bk,
    o.statecode                             AS state_code,
    o.statuscode                            AS status_code,
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


/* ---------- 3. fact_registration_end ----------
   Grain: one row per withdrawal or closure record.
   Source: dbo.asqa_rtowithdrawal UNION ALL dbo.asqa_rtoclosure.
   Columns one table lacks are NULL. */
SELECT
    w.Id                                        AS end_bk,
    'WITHDRAWAL'                                AS end_source,
    s.Id                                        AS submission_bk,
    w.asqa_account                              AS rto_bk,
    w.statecode                                 AS state_code,
    w.statuscode                                AS status_code,
    w.asqa_typeofregistrationforwithdrawal      AS registration_type_code,   -- 0 NVR, 1 ESOS, 2 both
    CAST(NULL AS bigint)                        AS regulatory_team_code,
    w.asqa_preferredwithdrawaleffectivedate     AS effective_date,           -- requested date
    w.createdon                                 AS created_date
FROM dbo.asqa_rtowithdrawal w
LEFT JOIN dbo.asqa_registrationsubmission s
       ON s.asqa_rtowithdrawal = w.Id
      AND s.IsDelete IS NULL
WHERE w.IsDelete IS NULL

UNION ALL

SELECT
    c.Id,
    'CLOSURE',
    s.Id,
    c.asqa_account_rtoclosure,
    c.statecode,
    c.statuscode,
    CAST(NULL AS bigint),
    c.asqa_regulatoryteam,
    c.asqa_dateofeffect,
    c.createdon
FROM dbo.asqa_rtoclosure c
LEFT JOIN dbo.asqa_registrationsubmission s
       ON s.asqa_rtoclosure = c.Id
      AND s.IsDelete IS NULL
WHERE c.IsDelete IS NULL;


/* ---------- 4. fact_measurement_period ----------
   Grain: one row per lapse or extension record.
   Source: dbo.asqa_rtolapsing UNION ALL dbo.asqa_rtoextendmeasurementperiod.
   lapse_type_code: 80000000 Lapsing, 80000001 Extended measurement period.
   Extension-table rows are set to 80000001 so the union has one type column.
   is_extension_in_effect is still unconfirmed (see BA questions). */
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


/* ---------- 5. fact_ownership_change ----------
   Grain: one row per ownership change record.
   Source: dbo.asqa_rtoownership, submission LEFT JOINed.
   submission_bk NULL = the change did not come through a submission. */
SELECT
    o.Id                                            AS ownership_change_bk,
    s.Id                                            AS submission_bk,
    o.asqa_accountid                                AS rto_bk,
    o.statecode                                     AS state_code,
    o.statuscode                                    AS status_code,
    o.asqa_dateofeffect                             AS effective_date,
    o.asqa_dateoflastdeliveryoftraining             AS last_delivery_date,
    o.asqa_totalpercentageofshares                  AS total_percentage_of_shares,
    TRY_CAST(o.asqa_noofenrolledstudents AS int)    AS enrolled_students,          -- text in source
    TRY_CAST(o.asqa_noofstudentpriortochange AS int) AS students_prior_to_change,  -- text in source
    CAST(CASE o.asqa_has50percentagesharechanged WHEN 100000000 THEN 1 WHEN 100000001 THEN 0 END AS bit) AS has_50pct_share_changed,
    o.asqa_ownershipstatus                          AS ownership_status_code,      -- 100000000 Active, 100000001 Expired
    CAST(CASE o.asqa_changeofownershipinfuture WHEN 100000000 THEN 1 WHEN 100000001 THEN 0 END AS bit) AS is_future_change,
    o.createdon                                     AS created_date
FROM dbo.asqa_rtoownership o
LEFT JOIN dbo.asqa_registrationsubmission s
       ON s.asqa_rtoownership = o.Id
      AND s.IsDelete IS NULL
WHERE o.IsDelete IS NULL;
-- Check: a non-NULL source text that comes back NULL after TRY_CAST is a non-numeric value.


/* ---------- 6. fact_ownership_share ----------
   Grain: one row per owner per ownership change.
   Source: dbo.asqa_rtoowner. TWO hops to the submission: the submission points at the
   ownership CHANGE, not the owner row, so owner -> change -> submission. */
SELECT
    o.Id                                AS owner_bk,
    oc.Id                               AS ownership_change_bk,
    s.Id                                AS submission_bk,
    o.asqa_rtoaccount                   AS rto_bk,
    o.asqa_companyid                    AS owner_company_bk,
    o.asqa_person                       AS owner_person_bk,         -- key only, details stay in a restricted dim
    o.statecode                         AS state_code,
    o.statuscode                        AS status_code,
    o.asqa_ownertype                    AS owner_type_code,         -- 100000000 Organisation, 100000001 Person
    CAST(CASE o.asqa_isthisanaustralianorganisation WHEN 100000001 THEN 1 WHEN 100000002 THEN 0 END AS bit) AS is_australian_org,
    o.asqa_dateofeffect                 AS date_of_effect,
    o.asqa_percentageofshares           AS percentage_of_shares,
    o.asqa_newpercentageofshares        AS new_percentage_of_shares,
    o.createdon                         AS created_date
FROM dbo.asqa_rtoowner o
LEFT JOIN dbo.asqa_rtoownership oc
       ON oc.Id = o.asqa_rtoownership
      AND oc.IsDelete IS NULL
LEFT JOIN dbo.asqa_registrationsubmission s
       ON s.asqa_rtoownership = oc.Id
      AND s.IsDelete IS NULL
WHERE o.IsDelete IS NULL;


/* ---------- 7. fact_scope_item ----------
   Grain: one row per scope item.
   Source: dbo.asqa_rtoscopeitem, with asqa_rtoscope for the header.
   Three routes to the submission, first hit wins:
     s1 : a submission points straight at the scope item
     s2 : a submission points at the scope header (asqa_rtoscopeapplication)  -- ASSUMED to point at asqa_rtoscope
     sc : the scope header points at the submission
   If two submissions point at the same scope header, s2 duplicates item rows. Check it.
   Student counts: two parallel pairs exist (LEAN, BA to say which is live). Both returned. */
SELECT
    i.Id                                                    AS scope_item_bk,
    sc.Id                                                   AS scope_bk,
    COALESCE(s1.Id, s2.Id, sc.asqa_registrationsubmission)  AS submission_bk,
    COALESCE(i.asqa_account, sc.asqa_account)               AS rto_bk,        -- item first, header as fallback
    i.asqa_registration                                     AS registration_bk,
    i.asqa_qualification                                    AS qualification_bk,
    i.asqa_accreditedunit                                   AS accredited_unit_bk,
    i.asqa_unit                                             AS unit_bk,
    i.asqa_course                                           AS course_bk,
    i.asqa_skillset                                         AS skillset_bk,
    i.asqa_elicoscourse                                     AS elicos_course_bk,
    i.asqa_typeofelicoscourse                               AS elicos_course_type_bk,
    i.asqa_broadfield                                       AS broad_field_bk,
    i.asqa_narrowfield                                      AS narrow_field_bk,
    i.asqa_detailedfield                                    AS detailed_field_bk,
    i.statecode                                             AS state_code,
    i.statuscode                                            AS status_code,
    sc.asqa_registrationtype                                AS scope_registration_type_code,
    i.asqa_typeofregistration                               AS registration_type_code,
    i.asqa_scopeitemstatus                                  AS scope_item_status_code,
    i.asqa_scopeitemtype                                    AS scope_item_type_code,
    i.asqa_decision                                         AS decision_code,
    i.asqa_scopedecisiontype                                AS decision_type_code,
    i.asqa_isrefused                                        AS is_refused,
    i.asqa_estimatedtotalnontuitionfees                     AS est_total_non_tuition_fees,
    i.asqa_estimatedtotaltuitionfees                        AS est_total_tuition_fees,
    i.asqa_totalestimatedcost                               AS total_estimated_cost,
    i.asqa_totalduration                                    AS total_duration,
    i.asqa_tuitioninweeks                                   AS tuition_weeks,
    i.asqa_holidaybreaksinweeks                             AS holiday_break_weeks,
    i.asqa_hoursforworkbasedtraining                        AS work_based_training_hours,
    i.asqa_weeksforworkbasedtraining                        AS work_based_training_weeks,
    i.asqa_totalworkcomponenthours                          AS total_work_component_hours,
    i.asqa_numberofdomesticstudents                         AS domestic_students,               -- LEAN
    i.asqa_numberofinternationalstudents                    AS international_students,          -- LEAN
    i.asqa_totalnumberofdomesticstudents                    AS total_domestic_students,         -- LEAN
    i.asqa_totalnumberofinternationalstudents               AS total_international_students,    -- LEAN
    i.asqa_dateoflastdelivery                               AS last_delivery_date,
    i.asqa_startdate                                        AS start_date,
    i.asqa_enddate                                          AS end_date,
    i.createdon                                             AS created_date
FROM dbo.asqa_rtoscopeitem i
LEFT JOIN dbo.asqa_rtoscope sc
       ON sc.Id = i.asqa_rtoscope
      AND sc.IsDelete IS NULL
LEFT JOIN dbo.asqa_registrationsubmission s1
       ON s1.asqa_rtoscopeitem = i.Id
      AND s1.IsDelete IS NULL
LEFT JOIN dbo.asqa_registrationsubmission s2
       ON s2.asqa_rtoscopeapplication = sc.Id
      AND s2.IsDelete IS NULL
WHERE i.IsDelete IS NULL;
