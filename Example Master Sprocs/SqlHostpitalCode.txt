ALTER PROC [dbo].[ExamMasterV1]
	-- external variables
	@EFname VARCHAR(35), @ELname VARCHAR(35), @EDOB DATE, @EWardID INT, @ECareteamID INT, @ECovidStatus VARCHAR(20)
AS
-- internal variables
DECLARE @IWardcapacity TINYINT, @IWardspec VARCHAR(25), @INoOfPatients TINYINT, @INoofDoctors TINYINT, @INoOfNurses TINYINT, @INoOfSpecNurses TINYINT, @IDay VARCHAR(12), @IAge TINYINT, @IPatientID INT, @ICareTeamFlag BIT = 1, @IName VARCHAR(100), @msgtext VARCHAR(1000), @msg VARCHAR(1000), @IAddNurseN INT, @IAddNurseP INT

SET NOCOUNT ON

-- do the reads
--read the data from the ward table
SELECT @IWardcapacity = WardCapacity, @IWardspec = WardSpeciality
FROM dbo.WardTbl
WHERE WardID = @EWardID

-- how many patients are there on this ward
SELECT @INoOfPatients = COUNT(*)
FROM dbo.PatientTbl
WHERE PatientWard = @EWardID

-- how many nurses are there on this care team
SELECT @INoOfNurses = COUNT(*)
FROM dbo.NurseCareTeamMembersTBL
WHERE CareTeamID = @ECareteamID
	AND CurrentMember = 1

-- how many nurses are there on this care team who have the speciality
SELECT @INoOfSpecNurses = count(*)
FROM dbo.NurseCareTeamMembersTBL AS nc
JOIN dbo.NurseTBL AS n ON nc.MemberID = n.NurseID
WHERE CareTeamID = @ECareteamID
	AND SUBSTRING(NurseSpeciality, (len(NurseSpeciality) - 2), 3) LIKE SUBSTRING(@IWardspec, 1, 3)
	AND CurrentMember = 1

-- how many doctors are there on this care team 
--who have the speciality
SELECT @INoofDoctors = COUNT(*)
FROM dbo.DoctorTbl AS d
INNER JOIN dbo.DoctorCareTeamMembersTBL AS dc ON d.DoctorID = dc.MemberID
WHERE CareTeamID = @ECareteamID
	AND SUBSTRING(DoctorSpeciality, (len(DoctorSpeciality) - 2), 3) LIKE SUBSTRING(@IWardspec, 1, 3)
	AND CurrentMember = 1

-- what day of the week is it
SELECT @IDay = DATENAME(dw, getdate())

--now populate the temp tables with available nurses from the ward
-- who are not active on 3 care teams
SELECT NurseID
INTO #t1
FROM dbo.NurseTBL AS n
JOIN dbo.NurseCareTeamMembersTBL AS c ON n.NurseID = c.MemberID
WHERE CurrentMember = 1
	AND NurseWard = @EWardID
	AND NURSEID NOT IN (
		SELECT MemberID
		FROM DBO.NurseCareTeamMembersTBL
		WHERE CurrentMember = @ECareteamID
		)
GROUP BY NurseID
HAVING count(*) < 3
-- add in those not assinged to a care team 
-- and have not been assinged to a ward
-- and have not been vaccinated

UNION

SELECT NurseID
FROM dbo.NurseTBL AS n
LEFT JOIN dbo.NurseCareTeamMembersTBL AS nc ON n.NurseID = nc.MemberID
WHERE nc.MemberID IS NULL
	AND NurseWard IS NULL
	AND COVID19Vacinated = 0

-- randomly select a nurse from this table
SELECT TOP 1 @IAddNurseN = NurseID
FROM #t1
ORDER BY newid()

-- now repeat this but this time 
-- get nurses that have been vaccinated
SELECT NurseID
INTO #t2
FROM dbo.NurseTBL AS n
JOIN dbo.NurseCareTeamMembersTBL AS c ON n.NurseID = c.MemberID
WHERE CurrentMember = 1
	AND NurseWard = @EWardID
	AND NURSEID NOT IN (
		SELECT MemberID
		FROM DBO.NurseCareTeamMembersTBL
		WHERE CurrentMember = @ECareteamID
			AND CareTeamID = 1
		)
GROUP BY NurseID
HAVING count(*) < 3
-- add in those not assinged to a care team 
-- and have not been assinged to a ward
-- and have  been vaccinated

UNION

SELECT NurseID
FROM dbo.NurseTBL AS n
LEFT JOIN dbo.NurseCareTeamMembersTBL AS nc ON n.NurseID = nc.MemberID
WHERE nc.MemberID IS NULL
	AND NurseWard IS NULL
	AND COVID19Vacinated = 1

-- now randomly select from this list
SELECT TOP 1 @IAddNurseP = NurseID
FROM #t2
ORDER BY newid()

-- Do The Logic
-- get the patients age
IF MONTH(@EDOB) <= MONTH(getdate())
	AND day(@EDOB) <= day(getdate())
BEGIN
	SELECT @IAge = DATEDIFF(yy, @EDOB, getdate())
END
ELSE
BEGIN
	SELECT @iage = (DATEDIFF(yy, @EDOB, getdate())) - 1
END

--is the ward full and its not a weekend
IF @IWardcapacity <= @INoOfPatients
BEGIN
	IF @iday NOT LIKE 'sunday'
		AND @IDay NOT LIKE 'saturday'
	BEGIN
		SELECT @IName = Upper(substring(@EFname, 1, 1)) + SUBSTRING(@EFname, 2, len(@EFname)) + ' ' + Upper(substring(@ELname, 1, 1)) + SUBSTRING(@ELname, 2, len(@ELname))

		SELECT @msgtext = N'This ward is overflowing – find a different ward for %s'

		SELECT @msg = FORMATMESSAGE(@msgtext, @IName);;

		THROW 50001, @msg, 1
	END
	ELSE
	--is the ward at 120% capacity and it is a weekend
	IF ceiling((@IWardcapacity * 1.2)) <= @INoOfPatients
	BEGIN
		SELECT @IName = Upper(substring(@EFname, 1, 1)) + SUBSTRING(@EFname, 2, len(@EFname)) + ' ' + Upper(substring(@ELname, 1, 1)) + SUBSTRING(@ELname, 2, len(@ELname))

		SELECT @msgtext = N'This ward is overflowing – find a different ward for %s'

		SELECT @msg = FORMATMESSAGE(@msgtext, @IName);;

		THROW 50001, @msg, 1
	END
END

-- what about the age rules
SELECT @msgtext = CASE 
		-- less that or equal to 13
		WHEN @IAge <= 13
			AND (
				@Iwardspec NOT LIKE '%Paeds13%'
				AND @IWardspec NOT LIKE '%Paediatrics13%'
				)
			THEN N'Patients in this ward must be 13 or younger'
				--age > 13 and M 15 ==> 14 years old check
		WHEN @IAge = 14
			AND (
				@Iwardspec NOT LIKE '%Paeds15%'
				AND @IWardspec NOT LIKE '%Paediatrics15%'
				)
			THEN N'Patients in this ward must be 14'
				--aged between 15 and 18 check
		WHEN @IAge BETWEEN 15
				AND 18
			AND (
				@IWardspec NOT LIKE '%paeds%'
				OR (
					@Iwardspec LIKE '%paeds13%'
					OR @IWardspec LIKE '%paeds15%'
					OR @Iwardspec LIKE '%paediatrics13%'
					OR @IWardspec LIKE '%paediatrics15%'
					)
				)
			THEN N'Patients between 15 and 18 not allowed in this ward'
		WHEN @IAge > 18
			AND (
				@IWardspec LIKE '%paeds%'
				OR (
					@Iwardspec LIKE '%paeds13%'
					OR @IWardspec LIKE '%paeds15%'
					OR @Iwardspec LIKE '%paediatrics13%'
					OR @IWardspec LIKE '%paediatrics15%'
					)
				)
			THEN N'Adults are not allowed on Children''s ward'
		ELSE NULL
		END

--if one of the ages causes a fail finish here
IF @msgtext IS NOT NULL
BEGIN
	SELECT @msg = FORMATMESSAGE(@msgtext);;

	THROW 50001, @msg, 1
END

--Now Do Care Team Rules
--is there a nurse with the speciality
IF @INoOfSpecNurses = 0
BEGIN
	SELECT @ICareTeamFlag = 0

	RAISERROR ('no nurse has the required speciality', 16, 1)
END

-- is there a doctor with the speciality
IF @INoofDoctors = 0
BEGIN
	SELECT @ICareTeamFlag = 0

	RAISERROR ('no doctor has the required speciality', 16, 1)
END

--enough current members for Covid Positive?
IF (
		@INoOfNurses < 3
		OR @INoofDoctors < 1
		)
	AND @ECovidStatus NOT LIKE 'Positive'
	AND @IAddNurseP IS NULL
BEGIN
	SELECT @ICareTeamFlag = 0

	RAISERROR ('not enough members available for the team', 16, 1)
END

-- enough current members for Covid Negative?
IF (
		@INoOfNurses < 3
		OR @INoofDoctors < 1
		)
	AND @ECovidStatus LIKE 'Negative'
	AND @IAddNursen IS NULL
BEGIN
	SELECT @ICareTeamFlag = 0

	RAISERROR ('not enough members available for the team', 16, 1)
END

--OK Business Rules have been passed
--Call other procs to do the inserts
--insert the patient
BEGIN TRY
	EXEC dbo.InsertPatient @eFname, @ELname, @EWardID, @ECovidStatus, @OPatientID = @IPatientID OUTPUT
END TRY

BEGIN CATCH
		;

	throw
END CATCH

-- add the nurse to the care team if there is one available
IF @IAddNurseN IS NOT NULL
BEGIN
	BEGIN TRY
		EXEC dbo.AddNurseToCareTeam @ECareTeamID, @IAddNurseN
	END TRY

	BEGIN CATCH
			;

		throw
	END CATCH
END

IF @IAddNurseP IS NOT NULL
BEGIN
	BEGIN TRY
		EXEC dbo.AddNurseToCareTeam @ECareTeamID, @IAddNurseP
	END TRY

	BEGIN CATCH
			;

		throw
	END CATCH
END

-- Assign the Patient to the Care Team if allowed 
IF @ICareTeamFlag = 1
BEGIN TRY
	EXEC dbo.InsertToCareTeam @eCareteamID, @IPatientID
END TRY

BEGIN CATCH
		;

	throw
END CATCH

--all ok do a cleanup of tem table
DROP TABLE #t1;

DROP TABLE #t2;

-- got here let them know
RAISERROR ('The Patient has been admitted', 16, 1)

RETURN 0