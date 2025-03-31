-- EXAMPLE 1: HOSPITAL PATIENT ADMISSION SYSTEM
-- Similar to the hospital example in your documents, this shows a patient admission system
-- with ward capacity checks, specialty matching, and care team validation

CREATE OR ALTER PROCEDURE dbo.HospitalAdmission
    @PatientFirstName VARCHAR(50),
    @PatientLastName VARCHAR(50),
    @PatientDOB DATE,
    @WardID INT,
    @CareTeamID INT,
    @PatientStatus VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Internal variables
    DECLARE @RetryCount INT = 0;
    DECLARE @MaxRetries INT = 3;
    DECLARE @CurrentDate DATE = GETDATE();
    DECLARE @PatientAge INT;
    DECLARE @WardCapacity INT;
    DECLARE @CurrentPatients INT;
    DECLARE @WardSpecialty VARCHAR(50);
    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @FormattedName VARCHAR(100);
    DECLARE @NurseCount INT;
    DECLARE @DoctorCount INT;
    DECLARE @NurseWithSpecialtyCount INT;
    DECLARE @DoctorWithSpecialtyCount INT;
    DECLARE @NewPatientID INT;
    DECLARE @IsWeekend BIT = 0;
    DECLARE @SpecialtyMatch BIT = 0;
    
    -- Transaction retry loop
    WHILE @RetryCount < @MaxRetries
    BEGIN
        BEGIN TRY
            -- Start transaction
            BEGIN TRANSACTION;
            
            -- Set lock resource for ward capacity
            DECLARE @LockResource VARCHAR(50) = 'WardCapacity_' + CAST(@WardID AS VARCHAR(10));
            DECLARE @LockResult INT;
            
            -- Get application lock
            EXEC @LockResult = sp_getapplock 
                @Resource = @LockResource,
                @LockMode = 'Exclusive',
                @LockOwner = 'Transaction',
                @LockTimeout = 5000;
                
            IF @LockResult < 0
            BEGIN
                -- Failed to acquire lock
                THROW 50001, 'Could not acquire lock for ward admission', 1;
            END
            
            -- Format patient name for error messages
            SET @FormattedName = UPPER(LEFT(@PatientFirstName, 1)) + 
                                LOWER(SUBSTRING(@PatientFirstName, 2, LEN(@PatientFirstName))) + 
                                ' ' + 
                                UPPER(LEFT(@PatientLastName, 1)) + 
                                LOWER(SUBSTRING(@PatientLastName, 2, LEN(@PatientLastName)));
            
            -- Get ward information
            SELECT 
                @WardCapacity = WardCapacity,
                @WardSpecialty = WardSpeciality
            FROM WardTBL
            WHERE WardID = @WardID;
            
            -- Count current patients in ward
            SELECT @CurrentPatients = COUNT(*)
            FROM PatientTBL
            WHERE PatientWard = @WardID;
            
            -- Check if it's weekend
            IF DATEPART(WEEKDAY, @CurrentDate) IN (1, 7)
                SET @IsWeekend = 1;
            
            -- Calculate patient age
            SET @PatientAge = DATEDIFF(YEAR, @PatientDOB, @CurrentDate);
            IF (MONTH(@PatientDOB) > MONTH(@CurrentDate) OR 
                (MONTH(@PatientDOB) = MONTH(@CurrentDate) AND DAY(@PatientDOB) > DAY(@CurrentDate)))
                SET @PatientAge = @PatientAge - 1;
            
            -- BUSINESS RULES - WARD CAPACITY
            -- Check ward capacity (non-weekend)
            IF @IsWeekend = 0 AND @CurrentPatients >= @WardCapacity
            BEGIN
                SET @ErrorMessage = 'This ward is full - find a different ward for ' + @FormattedName;
                THROW 50002, @ErrorMessage, 1;
            END
            
            -- Check ward capacity (weekend - allows 20% overflow)
            IF @IsWeekend = 1 AND @CurrentPatients >= (@WardCapacity * 1.2)
            BEGIN
                SET @ErrorMessage = 'This ward is overflowing - find a different ward for ' + @FormattedName;
                THROW 50003, @ErrorMessage, 1;
            END
            
            -- BUSINESS RULES - PATIENT AGE VS WARD SPECIALTY
            -- Age-based ward rules
            IF @PatientAge <= 13 AND @WardSpecialty NOT LIKE '%Paediatric13%' AND @WardSpecialty NOT LIKE '%Paeds 13%'
            BEGIN
                THROW 50004, 'Patient must be in ward with speciality Paediatric13 or Paeds 13', 1;
            END
            
            IF @PatientAge > 13 AND @PatientAge < 15 
               AND @WardSpecialty NOT LIKE '%Paediatric15%' AND @WardSpecialty NOT LIKE '%Paeds15%'
            BEGIN
                THROW 50005, 'Patient must be in ward with speciality Paediatric15 or Paeds15', 1;
            END
            
            IF @PatientAge BETWEEN 15 AND 18
               AND (@WardSpecialty NOT LIKE '%Paediatric%' AND @WardSpecialty NOT LIKE '%Paeds%'
                    OR @WardSpecialty LIKE '%Paediatric13%' OR @WardSpecialty LIKE '%Paeds 13%'
                    OR @WardSpecialty LIKE '%Paediatric15%' OR @WardSpecialty LIKE '%Paeds15%')
            BEGIN
                THROW 50006, 'Patient aged 15-18 cannot be in ward for younger patients', 1;
            END
            
            IF @PatientAge >= 18 AND (@WardSpecialty LIKE '%Paediatric%' OR @WardSpecialty LIKE '%Paeds%')
            BEGIN
                THROW 50007, 'Adult Patients cannot be in ward with speciality Paediatric or Paeds', 1;
            END
            
            -- BUSINESS RULES - CARE TEAM VALIDATION
            -- Get care team information
            DECLARE @WardSpecPrefix VARCHAR(3) = LEFT(@WardSpecialty, 3);
            
            -- Count doctors and nurses in care team
            SELECT @DoctorCount = COUNT(*)
            FROM DoctorCareTeamMembersTBL d
            JOIN DoctorTBL doc ON d.MemberID = doc.DoctorID
            WHERE d.CareTeamID = @CareTeamID
                AND d.CurrentMember = 1;
            
            SELECT @NurseCount = COUNT(*)
            FROM NurseCareTeamMembersTBL n
            WHERE n.CareTeamID = @CareTeamID
                AND n.CurrentMember = 1;
            
            -- Check for specialty matches
            SELECT @DoctorWithSpecialtyCount = COUNT(*)
            FROM DoctorCareTeamMembersTBL d
            JOIN DoctorTBL doc ON d.MemberID = doc.DoctorID
            WHERE d.CareTeamID = @CareTeamID
                AND d.CurrentMember = 1
                AND RIGHT(doc.DoctorSpeciality, 3) = @WardSpecPrefix;
            
            SELECT @NurseWithSpecialtyCount = COUNT(*)
            FROM NurseCareTeamMembersTBL n
            JOIN NurseTBL nurse ON n.MemberID = nurse.NurseID
            WHERE n.CareTeamID = @CareTeamID
                AND n.CurrentMember = 1
                AND RIGHT(nurse.NurseSpeciality, 3) = @WardSpecPrefix;
            
            -- Validate care team rules
            IF @DoctorCount < 1
            BEGIN
                THROW 50008, 'Care team must have at least one current doctor', 1;
            END
            
            IF @NurseCount < 1
            BEGIN
                THROW 50009, 'Care team must have at least one current nurse', 1;
            END
            
            -- Check specialty match
            IF @DoctorWithSpecialtyCount > 0 AND @NurseWithSpecialtyCount > 0
                SET @SpecialtyMatch = 1;
                
            IF @SpecialtyMatch = 0
            BEGIN
                THROW 50010, 'Care team must have at least one doctor and one nurse with matching specialty to the ward', 1;
            END
            
            -- BUSINESS RULES - COVID STATUS
            -- Check if additional nurse needed based on patient status
            DECLARE @NeedExtraNurse BIT = 0;
            DECLARE @SelectedNurseID INT = NULL;
            
            IF @NurseCount < 2
            BEGIN
                SET @NeedExtraNurse = 1;
                
                -- Find appropriate nurse based on patient status
                IF @PatientStatus = 'Negative'
                BEGIN
                    -- Try to get nurse from same ward
                    SELECT TOP 1 @SelectedNurseID = NurseID
                    FROM NurseTBL
                    WHERE NurseWarD = @WardID;
                    
                    -- If no ward nurse available, get unassigned nurse
                    IF @SelectedNurseID IS NULL
                    BEGIN
                        SELECT TOP 1 @SelectedNurseID = NurseID
                        FROM NurseTBL
                        WHERE NurseWarD IS NULL;
                    END
                END
                ELSE -- Patient is COVID positive or unknown
                BEGIN
                    -- Need vaccinated nurse
                    SELECT TOP 1 @SelectedNurseID = NurseID
                    FROM NurseTBL
                    WHERE COVID19Vacinated = 1
                        AND NurseWarD IS NULL;
                END
            END
            
            -- PERFORM ADMISSION OPERATIONS
            -- Update ward status if at overflow capacity (weekend only)
            IF @IsWeekend = 1 AND @CurrentPatients >= @WardCapacity
            BEGIN
                UPDATE WardTBL
                SET WardStatus = 'Overflow'
                WHERE WardID = @WardID;
            END
            
            -- Insert patient record
            EXEC InsertPatient
                @PatientFName = @PatientFirstName,
                @PatientLName = @PatientLastName,
                @PatientWardID = @WardID,
                @PatientCovidStatus = @PatientStatus,
                @PatientDependency = 'Med',
                @NewPatientID = @NewPatientID OUTPUT;
            
            -- Assign patient to care team
            EXEC InsertToCareTeam
                @PatientID = @NewPatientID,
                @CareTeamID = @CareTeamID;
            
            -- Add additional nurse if needed
            IF @NeedExtraNurse = 1 AND @SelectedNurseID IS NOT NULL
            BEGIN
                EXEC InsertNurse
                    @CareTeamID = @CareTeamID,
                    @NurseID = @SelectedNurseID;
            END
            
            -- Release the lock
            EXEC sp_releaseapplock
                @Resource = @LockResource,
                @LockOwner = 'Transaction';
                
            -- Commit transaction
            COMMIT TRANSACTION;
            
            -- Success message
            PRINT 'Patient ' + @FormattedName + ' successfully admitted to ward and assigned to care team';
            RETURN 0;
        END TRY
        BEGIN CATCH
            -- Check if transaction is active
            IF @@TRANCOUNT > 0
                ROLLBACK TRANSACTION;
            
            -- Error handling
            DECLARE @ErrorNum INT = ERROR_NUMBER();
            DECLARE @ErrorMsg NVARCHAR(4000) = ERROR_MESSAGE();
            
            -- Check if it's a deadlock (1205) or timeout
            IF @ErrorNum = 1205 OR @ErrorNum = 1222
            BEGIN
                SET @RetryCount = @RetryCount + 1;
                
                -- Max retries reached
                IF @RetryCount >= @MaxRetries
                BEGIN
                    THROW 50011, 'Transaction failed due to concurrency issues after maximum retry attempts', 1;
                END
                
                -- Wait before retrying
                WAITFOR DELAY '00:00:0' + CAST(@RetryCount AS VARCHAR(1));
                CONTINUE;
            END
            ELSE
            BEGIN
                -- Rethrow other errors
                THROW;
            END
        END CATCH
        
        -- Break loop on success
        BREAK;
    END
END;
GO