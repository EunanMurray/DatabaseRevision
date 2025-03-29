# SQL Server Isolation Levels & Variables Quick Reference

## Isolation Levels: When to Choose Which One

### READ UNCOMMITTED
* **When to use:** For reporting queries where absolute accuracy isn't critical but speed is essential
* **Example justification:** "READ UNCOMMITTED is appropriate here as we're generating non-critical reports and need maximum throughput. While we may see uncommitted data that could later be rolled back, this is acceptable for this reporting scenario since exact precision isn't required."
* **Concurrency issues prevented:** None (allows dirty reads, non-repeatable reads, phantom reads)
* **Impact on other transactions:** No blocking of other transactions

### READ COMMITTED (SQL Server default)
* **When to use:** For general-purpose OLTP operations where dirty reads must be avoided
* **Example justification:** "READ COMMITTED prevents our transaction from reading uncommitted data from other transactions that might be rolled back later. For example, without this level, we might read a temporary value for a patient's ward assignment that ultimately gets rolled back, leading to incorrect patient placement."
* **Concurrency issues prevented:** Dirty reads
* **Impact on other transactions:** Minimal blocking - only during updates to the same rows

### REPEATABLE READ
* **When to use:** For multi-step operations that need to see the same data values throughout a transaction
* **Example justification:** "REPEATABLE READ is necessary because we're performing multiple calculations based on the driver's penalty points. Without this level, another transaction could update the driver's points between our initial check and our final calculations, causing inconsistent policy pricing."
* **Concurrency issues prevented:** Dirty reads, non-repeatable reads
* **Impact on other transactions:** Moderate blocking - shared locks held until transaction completes

### SERIALIZABLE
* **When to use:** For critical financial transactions or when phantom reads must be prevented
* **Example justification:** "SERIALIZABLE is required for broker deletion because we need to ensure no new policies are created for this broker while we're determining if deletion is allowed. Without this level, a concurrent transaction could insert a new policy after our validation check but before our deletion completes, potentially violating our business rules."
* **Concurrency issues prevented:** Dirty reads, non-repeatable reads, phantom reads
* **Impact on other transactions:** Highest blocking - range locks prevent inserts/updates/deletes

### SNAPSHOT
* **When to use:** For reading consistent data without blocking writers
* **Example justification:** "SNAPSHOT isolation provides a consistent view of the data as it existed at the beginning of our transaction without blocking other transactions. This is ideal for our points update system, as we need to read player membership data consistently while allowing other transactions to continue modifying data."
* **Concurrency issues prevented:** Dirty reads, non-repeatable reads, phantom reads
* **Impact on other transactions:** No blocking but uses more tempdb space; update conflicts possible

## Variable Declaration Reference

### External Variables (Parameters)
* Always declare at the start of the procedure
* Use meaningful names that match business entities
* Include appropriate data types with suitable sizes
* Consider OUTPUT parameters for returning values
* For optional parameters, provide default values

```sql
CREATE OR ALTER PROCEDURE dbo.ProcessPolicy
    -- External variables (parameters)
    @DriverID INT,                           -- Simple input parameter
    @PolicyStartDate DATE,                   -- Date parameter
    @VehicleRegistration VARCHAR(20),        -- Text with appropriate length
    @BrokerID INT,                          
    @PremiumAmount DECIMAL(10,2),            -- Numeric with precision
    @NamedDrivers NamedDriversList READONLY, -- Table-valued parameter
    @NewPolicyID INT OUTPUT                  -- Output parameter
AS
```

### Internal Variables
* Declare all internal variables at the start of the procedure body
* Group related variables together
* Initialize variables with appropriate default values
* Consider variable scope and transaction context
* Name internal variables with a consistent prefix (@I, @Local, etc.) to distinguish from parameters

```sql
BEGIN
    -- Internal variables
    DECLARE @RetryCount INT = 0;                   -- Counter with initialization
    DECLARE @MaxRetries INT = 3;                   -- Constants/configuration
    DECLARE @CurrentDate DATE = GETDATE();         -- Date variables
    DECLARE @DriverAge INT;                        -- Calculated values
    DECLARE @BasePrice DECIMAL(10,2);              -- Business logic variables
    DECLARE @ErrorMessage NVARCHAR(4000);          -- Error handling
    DECLARE @FormattedName VARCHAR(100);           -- Formatting variables
    DECLARE @IsWeekend BIT = 0;                    -- Boolean flags

    -- Table variables
    DECLARE @NamedDriversPolicy TABLE (            -- Table variable
        PolicyID INT,
        DriverID INT
    );
```

### Table Variables and Temporary Tables
* Table variables (@Table): For smaller data sets, automatically cleaned up at end of batch
* Temporary tables (#Temp): For larger data sets, can have indexes, statistics, better for complex operations
* User-defined table types: For passing tabular data as parameters

```sql
-- Table variable
DECLARE @RecentBookings TABLE (
    BookingID INT,
    PlayerID INT,
    BookingDate DATE
);

-- Temporary table
CREATE TABLE #LargeResultSet (
    ID INT IDENTITY(1,1) PRIMARY KEY,
    Name VARCHAR(100),
    Value DECIMAL(10,2),
    Category VARCHAR(50)
);

-- Inserting data from one table type to another
INSERT INTO @NamedDriversPolicy (PolicyID, DriverID)
SELECT @NewPolicyID, DriverID
FROM @NamedDrivers;
```

## Common Patterns to Remember

### Age Calculation
```sql
-- Accurate age calculation
SET @Age = DATEDIFF(YEAR, @DateOfBirth, GETDATE());
IF (MONTH(@DateOfBirth) > MONTH(GETDATE()) OR 
    (MONTH(@DateOfBirth) = MONTH(GETDATE()) AND DAY(@DateOfBirth) > DAY(GETDATE())))
    SET @Age = @Age - 1;
```

### Name Formatting
```sql
-- Format first letter uppercase, rest lowercase
SET @FormattedName = UPPER(LEFT(@FirstName, 1)) + LOWER(SUBSTRING(@FirstName, 2, LEN(@FirstName))) + ' ' +
                    UPPER(LEFT(@LastName, 1)) + LOWER(SUBSTRING(@LastName, 2, LEN(@LastName)));
```

### Error Message Construction
```sql
-- Formatted error message
SET @ErrorMessage = 'The operation for "' + @FormattedName + '" with ID ' + 
                  CAST(@ID AS VARCHAR(10)) + ' has been rejected';
THROW 50001, @ErrorMessage, 1;
```