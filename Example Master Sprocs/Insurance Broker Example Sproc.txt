-- EXAMPLE 2: INSURANCE BROKER DELETION SYSTEM (FROM AUGUST 2023/2024 EXAM)
-- Based on the Zins Insurances exam scenario

CREATE OR ALTER PROCEDURE dbo.DeleteBroker
    @BrokerID INT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Delete broker record
    DELETE FROM Brokers
    WHERE BrokerID = @BrokerID;
    
    -- Return success
    PRINT 'Broker deleted successfully';
END;
GO

CREATE OR ALTER PROCEDURE dbo.OrphanPolicies
    @BrokerID INT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Update policies to set BrokerID to NULL
    UPDATE Policy
    SET BrokerID = NULL
    WHERE BrokerID = @BrokerID;
    
    -- Return success
    PRINT 'Policies orphaned successfully';
END;
GO

CREATE OR ALTER PROCEDURE dbo.MasterBrokerDelete
    @BrokerID INT
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Declare internal variables
    DECLARE @RetryCount INT = 0;
    DECLARE @MaxRetries INT = 3;
    DECLARE @CurrentYear INT = YEAR(GETDATE());
    DECLARE @HasCurrentYearPolicies BIT = 0;
    DECLARE @HasPreviousYearPolicies BIT = 0;
    DECLARE @BrokerFirstName VARCHAR(50);
    DECLARE @BrokerLastName VARCHAR(50);
    
    -- Set appropriate isolation level
    SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
    
    /*
    ISOLATION LEVEL JUSTIFICATION:
    
    1. What concurrency issues this isolation level prevents:
       SERIALIZABLE prevents dirty reads, non-repeatable reads, and phantom reads.
       This means our transaction won't see uncommitted data, data won't change between
       reads within our transaction, and no new rows will appear that match our query criteria.
       
    2. Example of issue in Zins database:
       Without SERIALIZABLE, a concurrent transaction could insert a new policy with this broker
       between our check for current-year policies and the actual broker deletion. This would
       violate our business rule that brokers with current-year policies cannot be deleted.
       
    3. Effect on other transactions:
       Other transactions will be blocked from inserting, updating, or deleting policies
       associated with this broker until our transaction completes. This ensures the broker's
       policy status doesn't change during our operation, maintaining data integrity.
    */
    
    -- Transaction retry loop
    WHILE @RetryCount < @MaxRetries
    BEGIN
        BEGIN TRY
            -- Begin transaction
            BEGIN TRANSACTION;
            
            -- Get broker details for error messages
            SELECT 
                @BrokerFirstName = FirstName,
                @BrokerLastName = LastName
            FROM Brokers
            WHERE BrokerID = @BrokerID;
            
            -- Format broker name
            DECLARE @FormattedBrokerName VARCHAR(100) = 
                UPPER(LEFT(@BrokerFirstName, 1)) + LOWER(SUBSTRING(@BrokerFirstName, 2, LEN(@BrokerFirstName))) + ' ' +
                UPPER(LEFT(@BrokerLastName, 1)) + LOWER(SUBSTRING(@BrokerLastName, 2, LEN(@BrokerLastName)));
            
            -- BUSINESS RULE 1: Check for current year policies
            SELECT @HasCurrentYearPolicies = 
                CASE WHEN EXISTS (
                    SELECT 1
                    FROM Policy
                    WHERE BrokerID = @BrokerID
                    AND YEAR(PolicyCommencementDate) = @CurrentYear
                ) THEN 1 ELSE 0 END;
            
            -- Cannot delete broker with current year policies
            IF @HasCurrentYearPolicies = 1
            BEGIN
                DECLARE @ErrorMsg NVARCHAR(200) = 'The delete for "' + @FormattedBrokerName + 
                                                '" whose Broker ID is ' + CAST(@BrokerID AS VARCHAR(10)) + ' is rejected';
                THROW 50001, @ErrorMsg, 1;
            END
            
            -- BUSINESS RULE 2: Check for previous year policies
            SELECT @HasPreviousYearPolicies = 
                CASE WHEN EXISTS (
                    SELECT 1
                    FROM Policy
                    WHERE BrokerID = @BrokerID
                    AND YEAR(PolicyCommencementDate) < @CurrentYear
                ) THEN 1 ELSE 0 END;
            
            -- Orphan previous year policies if they exist
            IF @HasPreviousYearPolicies = 1
            BEGIN
                EXEC OrphanPolicies @BrokerID = @BrokerID;
            END
            
            -- Delete the broker
            EXEC DeleteBroker @BrokerID = @BrokerID;
            
            -- Commit transaction
            COMMIT TRANSACTION;
            
            -- Return success
            PRINT 'Broker ' + @FormattedBrokerName + ' successfully deleted';
            RETURN 0;
        END TRY
        BEGIN CATCH
            -- Rollback on error
            IF @@TRANCOUNT > 0
                ROLLBACK TRANSACTION;
            
            -- Check for deadlock
            IF ERROR_NUMBER() = 1205
            BEGIN
                SET @RetryCount = @RetryCount + 1;
                
                IF @RetryCount >= @MaxRetries
                BEGIN
                    THROW 50002, 'Transaction has been terminated because of high usage - please retry', 1;
                END
                
                -- Wait before retry
                WAITFOR DELAY '00:00:03';
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

-- EXAMPLE 3: RECORD INSURANCE POLICY SALE (FROM JUNE 2023/2024 EXAM)

CREATE OR ALTER PROCEDURE dbo.InsertPolicy
    @DriverID INT,
    @InsurancePolicyID INT,
    @VehicleID INT,
    @BrokerID INT,
    @PolicyCost DECIMAL(10,2),
    @NewPolicyID INT OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Insert policy record
        INSERT INTO Policy (
            PolicyHolderID,
            InsurancePolicyID,
            VehicleID,
            BrokerID,
            PolicyCost,
            PolicyCommencementDate
        )
        VALUES (
            @DriverID,
            @InsurancePolicyID,
            @VehicleID,
            @BrokerID,
            @PolicyCost,
            GETDATE()
        );
        
        -- Get new policy ID
        SET @NewPolicyID = SCOPE_IDENTITY();
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.InsertNamedDrivers
    @NamedDriversPolicyList NamedDriverPolicyList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Insert named drivers
        INSERT INTO PolicyDrivers (PolicyID, DriverID)
        SELECT PolicyID, DriverID
        FROM @NamedDriversPolicyList;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.UpdateCommission
    @BrokerID INT,
    @CommissionAmount DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON;
    
    BEGIN TRY
        -- Update broker commission
        UPDATE Brokers
        SET Commission = Commission + @CommissionAmount
        WHERE BrokerID = @BrokerID;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.RecordPolicySale
    @DriverID INT,
    @InsurancePolicyID INT,
    @VehicleID INT,
    @BrokerID INT,
    @NamedDrivers NamedDriversList READONLY
AS
BEGIN
    SET NOCOUNT ON;
    
    -- Declare internal variables
    DECLARE @RetryCount INT = 0;
    DECLARE @MaxRetries INT = 3;
    DECLARE @PolicyCost DECIMAL(10,2);
    DECLARE @BasePrice DECIMAL(10,2);
    DECLARE @DriverAge INT;
    DECLARE @DriverDOB DATE;
    DECLARE @PenaltyPoints INT;
    DECLARE @CommissionAmount DECIMAL(10,2);
    DECLARE @NewPolicyID INT;
    
    -- Set isolation level
    SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
    
    /*
    ISOLATION LEVEL JUSTIFICATION:
    
    1. What concurrency issues this isolation level prevents:
       REPEATABLE READ prevents dirty reads and non-repeatable reads. This ensures
       that data we've read once in our transaction won't change if we read it again.
       
    2. Example of issue in Zins database:
       Without REPEATABLE READ, a concurrent transaction could update a driver's penalty 
       points between our initial check (which might show 7 points) and policy creation.
       If points increased to 9, we would create a policy that should have been rejected.
       
    3. Effect on other transactions:
       Other transactions can still insert new rows but cannot modify rows we've already
       read until our transaction completes. This provides good balance between data
       integrity and system concurrency.
    */
    
    -- Transaction retry loop
    WHILE @RetryCount < @MaxRetries
    BEGIN
        BEGIN TRY
            -- Begin transaction
            BEGIN TRANSACTION;
            
            -- Get driver information
            SELECT @DriverDOB = DateOfBirth
            FROM Driver
            WHERE DriverID = @DriverID;
            
            -- Calculate driver age
            SET @DriverAge = DATEDIFF(YEAR, @DriverDOB, GETDATE());
            IF (MONTH(@DriverDOB) > MONTH(GETDATE()) OR 
                (MONTH(@DriverDOB) = MONTH(GETDATE()) AND DAY(@DriverDOB) > DAY(GETDATE())))
                SET @DriverAge = @DriverAge - 1;
            
            -- Get base price for insurance policy
            SELECT @BasePrice = Price
            FROM InsurancePolicy
            WHERE InsurancePolicyID = @InsurancePolicyID;
            
            -- BUSINESS RULE 1: Calculate policy cost with age loading
            SET @PolicyCost = 
                CASE
                    WHEN @DriverAge < 21 THEN @BasePrice * 1.50 -- 50% loading
                    WHEN @DriverAge < 30 THEN @BasePrice * 1.25 -- 25% loading
                    WHEN @DriverAge < 35 THEN @BasePrice * 1.10 -- 10% loading
                    ELSE @BasePrice -- No loading
                END;
            
            -- BUSINESS RULE 2: Check penalty points
            SELECT @PenaltyPoints = ISNULL(SUM(Points), 0)
            FROM DriverPenaltyPoints
            WHERE DriverID = @DriverID;
            
            IF @PenaltyPoints > 8
            BEGIN
                THROW 50001, 'The Policy holder has exceeded 8 penalty points, so sale is rejected', 1;
            END
            
            -- BUSINESS RULE 3: Calculate commission
            SET @CommissionAmount = @PolicyCost * 0.035; -- 3.5% commission
            
            -- Insert policy
            EXEC InsertPolicy
                @DriverID = @DriverID,
                @InsurancePolicyID = @InsurancePolicyID,
                @VehicleID = @VehicleID,
                @BrokerID = @BrokerID,
                @PolicyCost = @PolicyCost,
                @NewPolicyID = @NewPolicyID OUTPUT;
            
            -- Insert named drivers if any
            IF EXISTS (SELECT 1 FROM @NamedDrivers)
            BEGIN
                -- Create table to hold named drivers with policy ID
                DECLARE @NamedDriversPolicy NamedDriverPolicyList;
                
                -- Populate with the new policy ID
                INSERT INTO @NamedDriversPolicy (PolicyID, DriverID)
                SELECT @NewPolicyID, DriverID
                FROM @NamedDrivers;
                
                -- Insert named drivers
                EXEC InsertNamedDrivers
                    @NamedDriversPolicyList = @NamedDriversPolicy;
            END
            
            -- Update broker's commission
            EXEC UpdateCommission
                @BrokerID = @BrokerID,
                @CommissionAmount = @CommissionAmount;
            
            -- Commit transaction
            COMMIT TRANSACTION;
            
            -- Return success
            PRINT 'Policy recorded successfully. Cost: ' + CAST(@PolicyCost AS VARCHAR(20)) + 
                  ', Commission: ' + CAST(@CommissionAmount AS VARCHAR(20));
            RETURN 0;
        END TRY
        BEGIN CATCH
            -- Rollback on error
            IF @@TRANCOUNT > 0
                ROLLBACK TRANSACTION;
            
            -- Check for deadlock
            IF ERROR_NUMBER() = 1205
            BEGIN
                SET @RetryCount = @RetryCount + 1;
                
                IF @RetryCount >= @MaxRetries
                BEGIN
                    THROW 50002, 'A conflict occurred with another user please resubmit the sale', 1;
                END
                
                -- Wait before retry
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