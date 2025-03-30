# SQL Stored Procedures Exam 

## Key Structure for Master Stored Procedure

```sql
CREATE OR ALTER PROCEDURE dbo.MasterProcedure
    @Param1 DataType,
    @Param2 DataType,
    @TableParam TableType READONLY
AS
BEGIN
    SET NOCOUNT ON;
    
    -- 1. DECLARE INTERNAL VARIABLES
    DECLARE @RetryCount INT = 0;
    DECLARE @MaxRetries INT = 3;
    DECLARE @ErrorMessage NVARCHAR(4000);
    DECLARE @OutputParam INT;
    
    -- 2. SET ISOLATION LEVEL
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED; 
    /* Always include a comment block explaining:
       1. What concurrency issues this prevents
       2. Example problem it would solve
       3. Effect on other transactions
    */
    
    -- 3. RETRY LOOP FOR DEADLOCK HANDLING
    WHILE @RetryCount < @MaxRetries
    BEGIN
        BEGIN TRY
            -- 4. BEGIN TRANSACTION
            BEGIN TRANSACTION;
            
            -- 5. BUSINESS RULE CHECKS
            IF NOT EXISTS (...) -- Your business rule check
            BEGIN
                THROW 50001, 'Your error message here', 1;
            END
            
            -- 6. CALL SUB-PROCEDURES
            EXEC SubProcedure1 @Param = @Param1, @Output = @OutputParam OUTPUT;
            EXEC SubProcedure2 @Param = @OutputParam;
            
            -- 7. COMMIT TRANSACTION
            COMMIT TRANSACTION;
            RETURN 0; -- Success
        END TRY
        BEGIN CATCH
            -- 8. ERROR HANDLING
            IF @@TRANCOUNT > 0
                ROLLBACK TRANSACTION;
                
            -- 9. DEADLOCK HANDLING
            IF ERROR_NUMBER() = 1205 -- Deadlock victim error
            BEGIN
                SET @RetryCount = @RetryCount + 1;
                
                IF @RetryCount >= @MaxRetries
                    THROW 50002, 'Max retries reached due to concurrency issues', 1;
                    
                WAITFOR DELAY '00:00:0' + CAST(@RetryCount AS VARCHAR(1));
                CONTINUE;
            END
            ELSE
                THROW; -- Re-throw other errors
        END CATCH
        
        BREAK; -- Exit loop on success
    END
END;
```

## Isolation Levels Reference

| Level | Prevents | Good For | Common Use |
|-------|----------|----------|------------|
| READ UNCOMMITTED | Nothing | Maximum throughput, reporting | `SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;` |
| READ COMMITTED | Dirty reads | General OLTP | `SET TRANSACTION ISOLATION LEVEL READ COMMITTED;` |
| REPEATABLE READ | Dirty reads, non-repeatable reads | Multi-step operations on same data | `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;` |
| SERIALIZABLE | Dirty reads, non-repeatable reads, phantom reads | Financial transactions, highest consistency | `SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;` |
| SNAPSHOT | Version-based isolation, readers don't block writers | Reporting against active OLTP | `SET TRANSACTION ISOLATION LEVEL SNAPSHOT;` |

## Common Business Logic Functions

### Age Calculation

```sql
-- Calculate age in years
DECLARE @DOB DATE = '2000-06-15';
DECLARE @Age INT = DATEDIFF(YEAR, @DOB, GETDATE());

-- More accurate calculation accounting for birthdate not yet occurred this year
IF (MONTH(@DOB) > MONTH(GETDATE())) OR 
   (MONTH(@DOB) = MONTH(GETDATE()) AND DAY(@DOB) > DAY(GETDATE()))
    SET @Age = @Age - 1;
```

### Name Formatting

```sql
-- Format first letter uppercase, rest lowercase
DECLARE @FirstName VARCHAR(50) = 'john';
DECLARE @LastName VARCHAR(50) = 'SMITH';

DECLARE @FormattedFirstName VARCHAR(50) = UPPER(LEFT(@FirstName, 1)) + LOWER(SUBSTRING(@FirstName, 2, LEN(@FirstName)));
DECLARE @FormattedLastName VARCHAR(50) = UPPER(LEFT(@LastName, 1)) + LOWER(SUBSTRING(@LastName, 2, LEN(@LastName)));

-- Concatenate for display
DECLARE @FullName VARCHAR(100) = @FormattedFirstName + ' ' + @FormattedLastName;
```

### Date/Time Operations

```sql
-- Check if date is in current year
IF YEAR(@DateToCheck) = YEAR(GETDATE())
    PRINT 'Current year';

-- Check for weekend
DECLARE @IsWeekend BIT = 0;
IF DATEPART(WEEKDAY, GETDATE()) IN (1, 7) -- Sat/Sun
    SET @IsWeekend = 1;

-- Time slot overlap check (e.g., for bookings)
IF EXISTS (
    SELECT 1
    FROM Bookings
    WHERE ResourceID = @ResourceID
      AND StartTime < @EndTime
      AND EndTime > @StartTime
)
    PRINT 'Overlapping booking';
```

### Percentage Calculations

```sql
-- Apply percentage loading
DECLARE @BaseAmount DECIMAL(10,2) = 500.00;
DECLARE @Age INT = 22;
DECLARE @FinalAmount DECIMAL(10,2);

SET @FinalAmount = @BaseAmount * 
    CASE
        WHEN @Age < 21 THEN 1.50 -- 50% loading
        WHEN @Age < 30 THEN 1.25 -- 25% loading
        WHEN @Age < 35 THEN 1.10 -- 10% loading
        ELSE 1.00 -- No loading
    END;
```

### Error Message Formatting

```sql
-- Build an error message with concatenation
DECLARE @ID INT = 123;
DECLARE @Name VARCHAR(50) = 'John Smith';
DECLARE @ErrorMsg NVARCHAR(200) = 'The operation for "' + @Name + '" with ID ' + CAST(@ID AS VARCHAR(10)) + ' failed.';

-- Using FORMATMESSAGE (system messages)
DECLARE @FormattedError NVARCHAR(4000) = FORMATMESSAGE(50001, @Name, @ID);
```

## Common Table-Valued Parameter Patterns

```sql
-- Table type should already be defined in the database
-- CREATE TYPE NamedDriversList AS TABLE (DriverID INT);

-- Create instance of table type
DECLARE @NamedDrivers NamedDriversList;

-- Insert values
INSERT INTO @NamedDrivers (DriverID) VALUES (101), (102);

-- Create table with data from another table type
DECLARE @DriverPolicyList DriverPolicyList;
INSERT INTO @DriverPolicyList (PolicyID, DriverID)
SELECT @NewPolicyID, DriverID
FROM @NamedDrivers;
```

## Transaction Management Patterns

### Basic Transaction

```sql
BEGIN TRY
    BEGIN TRANSACTION;
    
    -- Your operations here
    
    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;
    
    THROW; -- Re-throw error
END CATCH
```

### Deadlock Retry

```sql
DECLARE @RetryCount INT = 0;
DECLARE @MaxRetries INT = 3;
DECLARE @Success BIT = 0;

WHILE @RetryCount < @MaxRetries AND @Success = 0
BEGIN
    BEGIN TRY
        BEGIN TRANSACTION;
        
        -- Your operations here
        
        COMMIT TRANSACTION;
        SET @Success = 1; -- Success flag
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0
            ROLLBACK TRANSACTION;
        
        IF ERROR_NUMBER() = 1205 -- Deadlock victim error
        BEGIN
            SET @RetryCount = @RetryCount + 1;
            WAITFOR DELAY '00:00:0' + CAST(@RetryCount AS VARCHAR(1));
            
            IF @RetryCount >= @MaxRetries
                THROW 50000, 'Max deadlock retries reached', 1;
        END
        ELSE
            THROW; -- Re-throw other errors
    END CATCH
END
```

### Application Locks

```sql
DECLARE @LockResult INT;
DECLARE @LockResource VARCHAR(100) = 'CustomLock_' + CAST(@ResourceID AS VARCHAR(10));

-- Acquire lock
EXEC @LockResult = sp_getapplock
    @Resource = @LockResource,
    @LockMode = 'Exclusive',
    @LockOwner = 'Transaction',
    @LockTimeout = 5000;

IF @LockResult < 0
    THROW 50000, 'Failed to acquire lock', 1;

-- Operations with lock

-- Release lock (transaction will automatically release, but explicit is cleaner)
EXEC sp_releaseapplock
    @Resource = @LockResource,
    @LockOwner = 'Transaction';
```

## Important Error Numbers

- 1205: Deadlock victim
- 1222: Lock request timeout
- 3960, 3961: Snapshot isolation conflicts
- 50000+: Custom errors (user-defined)

## Exam Focus Areas

1. **Transaction Management**
   - Correct isolation level with justification
   - Deadlock handling
   - Proper transaction boundaries

2. **Business Rules**
   - Validate inputs before processing
   - Use appropriate error messages
   - Implement consistent checks across procedures

3. **Error Handling**
   - TRY-CATCH blocks
   - THROW statements with meaningful messages
   - Proper rollback if errors occur

4. **Procedure Structure**
   - Master procedure that calls sub-procedures
   - Sub-procedures that do specific tasks
   - Proper parameter handling
   - Return values or output parameters where needed

5. **Table-Valued Parameters**
   - Correctly define and use TVPs
   - Update sub-procedures that use TVPs
   - Handle nullable or empty TVPs
