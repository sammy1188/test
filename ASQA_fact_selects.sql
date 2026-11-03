/* ==========================================================================
   ASQA gold facts - source selects, v2
   Column names now match the model / column register.

   HOW EACH QUERY IS BUILT (same shape every time)
     Step 1  CTE "src"   : pull from the SOURCE table, keep the raw GUIDs, call them *_bk.
     Step 2  final SELECT: swap each *_bk for the surrogate *_sk by joining the gold dim.
                           No match (or NULL) becomes -1, the "Unknown" member.

   THE DRIVING TABLE IS THE EVENT
     Every query below starts FROM the child table (renewal, ownership, etc).
     The submission is LEFT JOINed on. NULL submission_bk means "this event did not
     come through a submission". It is not an error. It lands as submission_sk = -1.
     The only exception is fact_submission, where the submission is the event.

   ASSUMPTIONS - change these if they are wrong
     1. date_sk is yyyymmdd as int (20261103), -1 when the date is NULL.
        If your dim_date uses another key, swap the expression in one place.
     2. Gold dim names marked ASSUMED do not exist yet. Rename to your standard.
     3. Load order: dim_rto and the other dims first, then fact_submission,
        then the child facts (they look up fact_submission for submission_sk).
     4. Surrogate keys for the fact rows themselves (submission_sk, renewal_sk, etc)
        are IDENTITY / generated on insert, so they are not in these selects.
     5. IsDelete IS NULL means "not a deleted tombstone", same as before.
     6. NOT RUN. I cannot reach your Synapse. Syntax-check before you trust it.

   CHANGES FROM THE FIRST VERSION
     - _bk to _sk lookups added (fixes the rto_bk vs rto_sk mismatch).
     - Aliases renamed to the register / model names.
     - fact_ownership_change now carries future_change_code.
     - fact_registration_end, fact_measurement_period, fact_scope_item carry the
       three lean-include columns plus the student counts (marked LEAN below).
     - asqa_submitteddate casing fixed in fact_submission.
   ========================================================================== */


/* ==========================================================================
   1. fact_submission
   GRAIN    : one row per registration submission (not deleted).
   CAPTURES : the act of an RTO submitting something to ASQA, and where it stands.
   MEASURES : count of submissions by type / RTO / date / status. Approved flag.
   WHY      : this is the header. Type_sk (the GUID discriminator) tells you which
              kind of submission it is, so you can slice every other fact by it.
   NOTE     : here the submission IS the driving table, so there is no LEFT JOIN
              to a child.
   ========================================================================== */
WITH src AS (
    SELECT
        s.Id                                AS submission_bk,
        s.asqa_regsubid                     AS regsubid,              -- degenerate dimension
        s.asqa_requestreferenceid           AS request_reference_id,  -- degenerate dimension
        s.asqa_registrationsubmissiontype   AS type_bk,
        s.asqa_account                      AS rto_bk,
        s.asqa_submittedby                  AS submitted_by_bk,       -- key only, no name in the fact
        s.asqa_submissionmethod             AS submission_method_bk,
        s.asqa_origin                       AS origin_code,           -- labels not exported yet
        s.statecode                         AS state_code,
        s.statuscode                        AS status_code,
        s.asqa_submitteddate                AS submitted_date,        -- lower case d, was a typo before
        s.asqa_approved                     AS is_approved,
        s.createdon                         AS created_date,
        s.modifiedon                        AS modified_date
    FROM dbo.asqa_registrationsubmission s
    WHERE s.IsDelete IS NULL
)
SELECT
    src.submission_bk,
    src.regsubid,
    src.request_reference_id,
    COALESCE(t.submission_type_sk, -1)      AS type_sk,
    COALESCE(r.rto_sk, -1)                  AS rto_sk,
    COALESCE(c.contact_sk, -1)              AS submitted_by_sk,
    COALESCE(m.submission_method_sk, -1)    AS submission_method_sk,
    src.origin_code,
    src.state_code,
    src.status_code,
    src.is_approved,
    ISNULL(CONVERT(int, CONVERT(char(8), src.submitted_date, 112)), -1) AS submitted_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.created_date,   112)), -1) AS created_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.modified_date,  112)), -1) AS modified_date_sk
FROM src
LEFT JOIN gold.dim_submission_type   t ON t.submission_type_bk   = src.type_bk
LEFT JOIN gold.dim_rto               r ON r.rto_bk               = src.rto_bk
LEFT JOIN gold.dim_contact           c ON c.contact_bk           = src.submitted_by_bk       -- ASSUMED
LEFT JOIN gold.dim_submission_method m ON m.submission_method_bk = src.submission_method_bk; -- ASSUMED


/* ==========================================================================
   2. fact_renewal
   SOURCE   : dbo.asqa_rtorenewal  (the renewal is the event, submission is optional)
   GRAIN    : one row per renewal record (not deleted).
   CAPTURES : an RTO renewing its registration, the type, whether it was submitted,
              and when it is due.
   MEASURES : count of renewals, renewals due by month, submitted vs not.
   WHY      : renewal due date is the reportable date. The ~100 portal declaration
              questions (tick boxes) stay out, they are form answers, not events.
   NOTE     : renewals with no submission pointing at them still come through
              (submission_sk = -1) and still carry their own rto_sk.
   ========================================================================== */
WITH src AS (
    SELECT
        o.Id                                    AS renewal_bk,
        s.Id                                    AS submission_bk,   -- NULL = orphan renewal
        o.asqa_account                          AS rto_bk,
        o.statecode                             AS state_code,
        o.statuscode                            AS status_code,
        o.asqa_renewaltype                      AS renewal_type_code,
        o.asqa_typeofregistrationforrenewal     AS registration_type_code, -- asqa_typeofregistrationforrenew may be a duplicate, see BA questions
        o.asqa_renewalsubmitted                 AS is_renewal_submitted,
        o.asqa_setrenewalduedate                AS renewal_due_date,
        o.createdon                             AS created_date
    FROM dbo.asqa_rtorenewal o
    LEFT JOIN dbo.asqa_registrationsubmission s
           ON s.asqa_rtorenewal = o.Id
          AND s.IsDelete IS NULL
    WHERE o.IsDelete IS NULL
)
SELECT
    src.renewal_bk,
    COALESCE(fs.submission_sk, -1)          AS submission_sk,
    COALESCE(r.rto_sk, -1)                  AS rto_sk,
    src.state_code,
    src.status_code,
    src.renewal_type_code,
    src.registration_type_code,
    src.is_renewal_submitted,
    ISNULL(CONVERT(int, CONVERT(char(8), src.renewal_due_date, 112)), -1) AS renewal_due_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.created_date,     112)), -1) AS created_date_sk
FROM src
LEFT JOIN gold.fact_submission fs ON fs.submission_bk = src.submission_bk
LEFT JOIN gold.dim_rto         r  ON r.rto_bk         = src.rto_bk;


/* ==========================================================================
   3. fact_registration_end
   SOURCE   : dbo.asqa_rtowithdrawal UNION ALL dbo.asqa_rtoclosure
   GRAIN    : one row per withdrawal or closure record (not deleted).
   CAPTURES : a registration coming to an end, either the RTO asking (withdrawal)
              or ASQA closing it (closure). end_source says which.
   MEASURES : count of registrations ended, by month, by reason type.
   WHY      : both have a "date of effect". Merging them is a BA question (see
              BA questions sheet). If the answer is no, split this in two.
   NOTE     : each table has columns the other does not, so those are NULL here.
   ========================================================================== */
WITH src AS (
    SELECT
        w.Id                                        AS end_bk,
        'WITHDRAWAL'                                AS end_source,
        s.Id                                        AS submission_bk,
        w.asqa_account                              AS rto_bk,
        w.statecode                                 AS state_code,
        w.statuscode                                AS status_code,
        w.asqa_typeofregistrationforwithdrawal      AS registration_type_code,  -- LEAN: confirm meaning
        CAST(NULL AS bigint)                        AS regulatory_team_code,
        w.asqa_preferredwithdrawaleffectivedate     AS effective_date,          -- requested date
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
    WHERE c.IsDelete IS NULL
)
SELECT
    src.end_bk,
    src.end_source,
    COALESCE(fs.submission_sk, -1)          AS submission_sk,
    COALESCE(r.rto_sk, -1)                  AS rto_sk,
    src.state_code,
    src.status_code,
    src.registration_type_code,
    src.regulatory_team_code,
    ISNULL(CONVERT(int, CONVERT(char(8), src.effective_date, 112)), -1) AS effective_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.created_date,   112)), -1) AS created_date_sk
FROM src
LEFT JOIN gold.fact_submission fs ON fs.submission_bk = src.submission_bk
LEFT JOIN gold.dim_rto         r  ON r.rto_bk         = src.rto_bk;


/* ==========================================================================
   4. fact_measurement_period
   SOURCE   : dbo.asqa_rtolapsing UNION ALL dbo.asqa_rtoextendmeasurementperiod
   GRAIN    : one row per lapse or extension record (not deleted).
   CAPTURES : the window an RTO has to deliver training before its registration
              can lapse, and any extension to that window or nil-delivery period.
   MEASURES : count of lapse / extension records, length of periods, extensions
              granted.
   WHY      : both tables are the same business idea (a measurement period and
              changes to it). period_source says which table the row came from.
   NOTE     : LEAN columns are lapse_type_code and is_extension_in_effect. They
              were missing from the first version.
   ========================================================================== */
WITH src AS (
    SELECT
        l.Id                                                AS period_bk,
        'LAPSING'                                           AS period_source,
        s.Id                                                AS submission_bk,
        l.asqa_rtoaccount                                   AS rto_bk,
        l.statecode                                         AS state_code,
        l.statuscode                                        AS status_code,
        l.asqa_origin                                       AS origin_code,
        l.asqa_type                                         AS lapse_type_code,           -- LEAN
        l.asqa_isanextensiontomeasurementperiodineffecty    AS is_extension_in_effect,    -- LEAN
        CAST(NULL AS bigint)                                AS request_for_code,
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
        CAST(NULL AS bigint),
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
    WHERE e.IsDelete IS NULL
)
SELECT
    src.period_bk,
    src.period_source,
    COALESCE(fs.submission_sk, -1)          AS submission_sk,
    COALESCE(r.rto_sk, -1)                  AS rto_sk,
    src.state_code,
    src.status_code,
    src.origin_code,
    src.lapse_type_code,
    src.is_extension_in_effect,
    src.request_for_code,
    ISNULL(CONVERT(int, CONVERT(char(8), src.measurement_period_start_date,   112)), -1) AS measurement_period_start_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.measurement_period_end_date,     112)), -1) AS measurement_period_end_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.extension_start_date,            112)), -1) AS extension_start_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.extension_end_date,              112)), -1) AS extension_end_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.requested_extension_start_date,  112)), -1) AS requested_extension_start_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.requested_extension_end_date,    112)), -1) AS requested_extension_end_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.nil_delivery_start_date,         112)), -1) AS nil_delivery_start_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.nil_delivery_end_date,           112)), -1) AS nil_delivery_end_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.last_delivery_date,              112)), -1) AS last_delivery_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.created_date,                    112)), -1) AS created_date_sk
FROM src
LEFT JOIN gold.fact_submission fs ON fs.submission_bk = src.submission_bk
LEFT JOIN gold.dim_rto         r  ON r.rto_bk         = src.rto_bk;


/* ==========================================================================
   5. fact_ownership_change
   SOURCE   : dbo.asqa_rtoownership  (the ownership change is the event)
   GRAIN    : one row per ownership change record (not deleted).
   CAPTURES : a change of ownership of an RTO, when it takes effect, how much of
              the shares changed hands, and how many students are affected.
   MEASURES : total_percentage_of_shares, enrolled_students,
              students_prior_to_change, count of changes, 50% shift flag.
   WHY      : effective date plus student impact. Accountant contact details stay
              out because they are personal.
   NOTE     : submission_sk = -1 means no submission points at this change. That
              is why the ownership table is the real source and the submission is
              just an optional link.
   ========================================================================== */
WITH src AS (
    SELECT
        o.Id                                        AS ownership_change_bk,
        s.Id                                        AS submission_bk,
        o.asqa_accountid                            AS rto_bk,
        o.statecode                                 AS state_code,
        o.statuscode                                AS status_code,
        o.asqa_dateofeffect                         AS effective_date,
        o.asqa_dateoflastdeliveryoftraining         AS last_delivery_date,
        o.asqa_totalpercentageofshares              AS total_percentage_of_shares,
        TRY_CAST(o.asqa_noofenrolledstudents   AS int) AS enrolled_students,           -- text in source
        TRY_CAST(o.asqa_noofstudentpriortochange AS int) AS students_prior_to_change,  -- text in source
        o.asqa_has50percentagesharechanged          AS has_50pct_share_changed,
        o.asqa_ownershipstatus                      AS ownership_status_code,
        o.asqa_changeofownershipinfuture            AS future_change_code,
        o.createdon                                 AS created_date
    FROM dbo.asqa_rtoownership o
    LEFT JOIN dbo.asqa_registrationsubmission s
           ON s.asqa_rtoownership = o.Id
          AND s.IsDelete IS NULL
    WHERE o.IsDelete IS NULL
)
SELECT
    src.ownership_change_bk,
    COALESCE(fs.submission_sk, -1)          AS submission_sk,
    COALESCE(r.rto_sk, -1)                  AS rto_sk,
    src.state_code,
    src.status_code,
    src.total_percentage_of_shares,
    src.enrolled_students,
    src.students_prior_to_change,
    src.has_50pct_share_changed,
    src.ownership_status_code,
    src.future_change_code,
    ISNULL(CONVERT(int, CONVERT(char(8), src.effective_date,     112)), -1) AS effective_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.last_delivery_date, 112)), -1) AS last_delivery_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.created_date,       112)), -1) AS created_date_sk
FROM src
LEFT JOIN gold.fact_submission fs ON fs.submission_bk = src.submission_bk
LEFT JOIN gold.dim_rto         r  ON r.rto_bk         = src.rto_bk;
-- Check TRY_CAST: any enrolled_students NULL where the source text is not NULL
-- means a non-numeric value like 'approx 50' got dropped.


/* ==========================================================================
   6. fact_ownership_share
   SOURCE   : dbo.asqa_rtoowner  (one row per owner per ownership change)
   GRAIN    : one row per owner row (not deleted).
   CAPTURES : who owns what share of the RTO, and the new share after a change.
   MEASURES : percentage_of_shares, new_percentage_of_shares.
   WHY      : lets you see ownership concentration and how it moved.
   NOTE     : TWO HOPS to the submission. The submission points at the ownership
              CHANGE, not at the owner row, so we go owner -> change -> submission.
              A share row with no change, or a change with no submission, gets
              submission_sk = -1.
              Owner key columns are keys only. Person details stay in a restricted dim.
   ========================================================================== */
WITH src AS (
    SELECT
        o.Id                                AS owner_bk,
        oc.Id                               AS ownership_change_bk,
        s.Id                                AS submission_bk,
        o.asqa_rtoaccount                   AS rto_bk,
        o.asqa_companyid                    AS owner_company_bk,
        o.asqa_person                       AS owner_person_bk,
        o.statecode                         AS state_code,
        o.statuscode                        AS status_code,
        o.asqa_ownertype                    AS owner_type_code,
        o.asqa_isthisanaustralianorganisation AS is_australian_org,
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
    WHERE o.IsDelete IS NULL
)
SELECT
    src.owner_bk,
    COALESCE(foc.ownership_change_sk, -1)   AS ownership_change_sk,  -- plain column, not an enforced FK
    COALESCE(fs.submission_sk, -1)          AS submission_sk,
    COALESCE(r.rto_sk, -1)                  AS rto_sk,
    COALESCE(oco.owner_company_sk, -1)      AS owner_company_sk,
    COALESCE(op.owner_person_sk, -1)        AS owner_person_sk,
    src.state_code,
    src.status_code,
    src.owner_type_code,
    src.is_australian_org,
    src.percentage_of_shares,
    src.new_percentage_of_shares,
    ISNULL(CONVERT(int, CONVERT(char(8), src.date_of_effect, 112)), -1) AS date_of_effect_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.created_date,   112)), -1) AS created_date_sk
FROM src
LEFT JOIN gold.fact_ownership_change foc ON foc.ownership_change_bk = src.ownership_change_bk
LEFT JOIN gold.fact_submission       fs  ON fs.submission_bk        = src.submission_bk
LEFT JOIN gold.dim_rto               r   ON r.rto_bk                = src.rto_bk
LEFT JOIN gold.dim_owner_company     oco ON oco.owner_company_bk    = src.owner_company_bk  -- ASSUMED
LEFT JOIN gold.dim_owner_person      op  ON op.owner_person_bk      = src.owner_person_bk;  -- ASSUMED, restricted


/* ==========================================================================
   7. fact_scope_item
   SOURCE   : dbo.asqa_rtoscopeitem  (+ asqa_rtoscope for the header)
   GRAIN    : one row per scope item (a qualification, unit, course or skill set
              an RTO is or wants to be registered to deliver).
   CAPTURES : what an RTO is approved (or applying) to deliver, the decision on
              it, the fees and hours, and the student numbers.
   MEASURES : fees, durations, work-based-training hours, student counts.
   WHY      : this is the one with real numbers. It is also the one with the
              messiest link to a submission.
   NOTE     : THREE ways to find the submission, tried in order:
                s1 : a submission points straight at the scope item
                s2 : a submission points at the scope header (asqa_rtoscopeapplication)
                sc : the scope header points at the submission itself
              I ASSUMED asqa_rtoscopeapplication points at asqa_rtoscope. If s2
              never matches anything, check that first.
              If two submissions point at the same scope header, s2 duplicates the
              item rows. Check rows vs distinct scope_item_bk after you run it.
              Which product key is filled depends on the item type: a qualification
              item has qualification_bk and nothing in unit_bk, and so on.
              Student counts are LEAN: two parallel pairs exist, the BA must say
              which pair is live. Both are here until then.
   ========================================================================== */
WITH src AS (
    SELECT
        i.Id                                        AS scope_item_bk,
        sc.Id                                       AS scope_bk,
        COALESCE(s1.Id, s2.Id, sc.asqa_registrationsubmission) AS submission_bk,
        COALESCE(i.asqa_account, sc.asqa_account)   AS rto_bk,      -- item first, header as fallback
        i.asqa_registration                         AS registration_bk,
        i.asqa_qualification                        AS qualification_bk,
        i.asqa_accreditedunit                       AS accredited_unit_bk,
        i.asqa_unit                                 AS unit_bk,
        i.asqa_course                               AS course_bk,
        i.asqa_skillset                             AS skillset_bk,
        i.asqa_elicoscourse                         AS elicos_course_bk,
        i.asqa_typeofelicoscourse                   AS elicos_course_type_bk,
        i.asqa_broadfield                           AS broad_field_bk,
        i.asqa_narrowfield                          AS narrow_field_bk,
        i.asqa_detailedfield                        AS detailed_field_bk,
        i.statecode                                 AS state_code,
        i.statuscode                                AS status_code,
        sc.asqa_registrationtype                    AS scope_registration_type_code, -- header. Renamed so it does not clash with the item's
        i.asqa_typeofregistration                   AS registration_type_code,
        i.asqa_scopeitemstatus                      AS scope_item_status_code,
        i.asqa_scopeitemtype                        AS scope_item_type_code,
        i.asqa_decision                             AS decision_code,
        i.asqa_scopedecisiontype                    AS decision_type_code,
        i.asqa_isrefused                            AS is_refused,
        i.asqa_estimatedtotalnontuitionfees         AS est_total_non_tuition_fees,
        i.asqa_estimatedtotaltuitionfees            AS est_total_tuition_fees,
        i.asqa_totalestimatedcost                   AS total_estimated_cost,
        i.asqa_totalduration                        AS total_duration,
        i.asqa_tuitioninweeks                       AS tuition_weeks,
        i.asqa_holidaybreaksinweeks                 AS holiday_break_weeks,
        i.asqa_hoursforworkbasedtraining            AS work_based_training_hours,
        i.asqa_weeksforworkbasedtraining            AS work_based_training_weeks,
        i.asqa_totalworkcomponenthours              AS total_work_component_hours,
        i.asqa_numberofdomesticstudents             AS domestic_students,                 -- LEAN
        i.asqa_numberofinternationalstudents        AS international_students,            -- LEAN
        i.asqa_totalnumberofdomesticstudents        AS total_domestic_students,           -- LEAN
        i.asqa_totalnumberofinternationalstudents   AS total_international_students,      -- LEAN
        i.asqa_dateoflastdelivery                   AS last_delivery_date,
        i.asqa_startdate                            AS start_date,
        i.asqa_enddate                              AS end_date,
        i.createdon                                 AS created_date
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
    WHERE i.IsDelete IS NULL
)
SELECT
    src.scope_item_bk,
    src.scope_bk,
    COALESCE(fs.submission_sk, -1)          AS submission_sk,
    COALESCE(r.rto_sk, -1)                  AS rto_sk,
    COALESCE(rg.registration_sk, -1)        AS registration_sk,
    COALESCE(q.qualification_sk, -1)        AS qualification_sk,
    COALESCE(au.accredited_unit_sk, -1)     AS accredited_unit_sk,
    COALESCE(u.unit_sk, -1)                 AS unit_sk,
    COALESCE(co.course_sk, -1)              AS course_sk,
    COALESCE(sk.skillset_sk, -1)            AS skillset_sk,
    COALESCE(ec.elicos_course_sk, -1)       AS elicos_course_sk,
    COALESCE(et.elicos_course_type_sk, -1)  AS elicos_course_type_sk,
    COALESCE(bf.field_of_education_sk, -1)  AS broad_field_sk,
    COALESCE(nf.field_of_education_sk, -1)  AS narrow_field_sk,
    COALESCE(df.field_of_education_sk, -1)  AS detailed_field_sk,
    src.state_code,
    src.status_code,
    src.scope_registration_type_code,
    src.registration_type_code,
    src.scope_item_status_code,
    src.scope_item_type_code,
    src.decision_code,
    src.decision_type_code,
    src.is_refused,
    src.est_total_non_tuition_fees,
    src.est_total_tuition_fees,
    src.total_estimated_cost,
    src.total_duration,
    src.tuition_weeks,
    src.holiday_break_weeks,
    src.work_based_training_hours,
    src.work_based_training_weeks,
    src.total_work_component_hours,
    src.domestic_students,
    src.international_students,
    src.total_domestic_students,
    src.total_international_students,
    ISNULL(CONVERT(int, CONVERT(char(8), src.last_delivery_date, 112)), -1) AS last_delivery_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.start_date,         112)), -1) AS start_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.end_date,           112)), -1) AS end_date_sk,
    ISNULL(CONVERT(int, CONVERT(char(8), src.created_date,       112)), -1) AS created_date_sk
FROM src
LEFT JOIN gold.fact_submission        fs ON fs.submission_bk        = src.submission_bk
LEFT JOIN gold.dim_rto                r  ON r.rto_bk                = src.rto_bk
LEFT JOIN gold.dim_registration       rg ON rg.registration_bk      = src.registration_bk       -- ASSUMED
LEFT JOIN gold.dim_qualification      q  ON q.qualification_bk      = src.qualification_bk      -- ASSUMED
LEFT JOIN gold.dim_accredited_unit    au ON au.accredited_unit_bk   = src.accredited_unit_bk    -- ASSUMED
LEFT JOIN gold.dim_unit               u  ON u.unit_bk               = src.unit_bk               -- ASSUMED
LEFT JOIN gold.dim_course             co ON co.course_bk            = src.course_bk             -- ASSUMED
LEFT JOIN gold.dim_skillset           sk ON sk.skillset_bk          = src.skillset_bk           -- ASSUMED
LEFT JOIN gold.dim_elicos_course      ec ON ec.elicos_course_bk     = src.elicos_course_bk      -- ASSUMED
LEFT JOIN gold.dim_elicos_course_type et ON et.elicos_course_type_bk = src.elicos_course_type_bk -- ASSUMED
LEFT JOIN gold.dim_field_of_education bf ON bf.field_of_education_bk = src.broad_field_bk       -- ASSUMED, one dim, three roles
LEFT JOIN gold.dim_field_of_education nf ON nf.field_of_education_bk = src.narrow_field_bk
LEFT JOIN gold.dim_field_of_education df ON df.field_of_education_bk = src.detailed_field_bk;
