SET SERVEROUTPUT ON
SET FEEDBACK ON

-- ============================================================================
-- XX_COLLECTIONS_TASK_PKG - Collections Task Creation via ISG REST
-- Registered with iRep as XxCollectionsTaskPkg
-- ============================================================================

CREATE OR REPLACE PACKAGE APPS.XX_COLLECTIONS_TASK_PKG AS
/* $Header: XX_COLLECTIONS_TASK_PKG.pls 1.0 2026/03/17 00:00:00 applmgr ship $ */
/*#
 * Public API for creating collections tasks in Oracle EBS.
 * Wraps JTF_TASKS_PUB.CREATE_TASK for ISG REST access.
 *
 * @rep:scope public
 * @rep:product AR
 * @rep:displayname Collections Task Management
 * @rep:lifecycle active
 * @rep:compatibility S
 * @rep:category BUSINESS_ENTITY IEX_STRATEGY
 */

/*#
 * Creates a collections follow-up task linked to a customer account.
 *
 * @param p_cust_account_id Customer Account ID (source object)
 * @param p_task_name Task name/subject
 * @param p_task_notes Task description/notes
 * @param p_due_date Due date in YYYY-MM-DD format (defaults to +7 days)
 * @param x_return_status Return status: S=Success, E=Error
 * @param x_msg_count Number of messages
 * @param x_msg_data Error message text
 * @param x_task_id Created task ID
 * @rep:scope public
 * @rep:lifecycle active
 * @rep:displayname Create Collections Task
 */
PROCEDURE CREATE_TASK (
  p_cust_account_id  IN  NUMBER,
  p_task_name        IN  VARCHAR2 DEFAULT 'Collections Follow-up',
  p_task_notes       IN  VARCHAR2 DEFAULT NULL,
  p_due_date         IN  VARCHAR2 DEFAULT NULL,
  x_return_status    OUT NOCOPY VARCHAR2,
  x_msg_count        OUT NOCOPY NUMBER,
  x_msg_data         OUT NOCOPY VARCHAR2,
  x_task_id          OUT NOCOPY NUMBER
);

END XX_COLLECTIONS_TASK_PKG;
/
SHOW ERRORS;

CREATE OR REPLACE PACKAGE BODY APPS.XX_COLLECTIONS_TASK_PKG AS

PROCEDURE CREATE_TASK (
  p_cust_account_id  IN  NUMBER,
  p_task_name        IN  VARCHAR2 DEFAULT 'Collections Follow-up',
  p_task_notes       IN  VARCHAR2 DEFAULT NULL,
  p_due_date         IN  VARCHAR2 DEFAULT NULL,
  x_return_status    OUT NOCOPY VARCHAR2,
  x_msg_count        OUT NOCOPY NUMBER,
  x_msg_data         OUT NOCOPY VARCHAR2,
  x_task_id          OUT NOCOPY NUMBER
) IS
  l_task_id    NUMBER;
  l_due        DATE;
  l_msg        VARCHAR2(2000);
BEGIN
  x_return_status := FND_API.G_RET_STS_SUCCESS;

  FND_GLOBAL.APPS_INITIALIZE(0, 20678, 222);
  MO_GLOBAL.SET_POLICY_CONTEXT('S', 204);

  -- Parse due date or default to +7 days
  IF p_due_date IS NOT NULL THEN
    l_due := TO_DATE(p_due_date, 'YYYY-MM-DD');
  ELSE
    l_due := SYSDATE + 7;
  END IF;

  JTF_TASKS_PUB.CREATE_TASK(
    p_api_version             => 1.0,
    p_init_msg_list           => FND_API.G_TRUE,
    p_commit                  => FND_API.G_TRUE,
    p_task_name               => SUBSTR(p_task_name, 1, 80),
    p_task_type_name          => 'Other',
    p_task_status_name        => 'Open',
    p_task_priority_name      => 'High',
    p_owner_type_code         => 'RS_EMPLOYEE',
    p_owner_id                => FND_GLOBAL.EMPLOYEE_ID,
    p_description             => SUBSTR(p_task_notes, 1, 2000),
    p_planned_start_date      => SYSDATE,
    p_planned_end_date        => l_due,
    p_source_object_type_code => 'IEX_ACCOUNT',
    p_source_object_id        => p_cust_account_id,
    p_source_object_name      => 'Customer ' || p_cust_account_id,
    x_return_status           => x_return_status,
    x_msg_count               => x_msg_count,
    x_msg_data                => x_msg_data,
    x_task_id                 => l_task_id
  );

  x_task_id := l_task_id;

  IF x_return_status = FND_API.G_RET_STS_SUCCESS THEN
    COMMIT;
  ELSE
    -- Collect all messages
    IF x_msg_count > 1 THEN
      DECLARE
        l_all VARCHAR2(4000) := '';
      BEGIN
        FOR i IN 1..x_msg_count LOOP
          l_msg := FND_MSG_PUB.GET(p_msg_index => i, p_encoded => FND_API.G_FALSE);
          l_all := l_all || '[' || i || '] ' || NVL(l_msg, '') || ' ';
        END LOOP;
        x_msg_data := SUBSTR(l_all, 1, 2000);
      END;
    END IF;
    ROLLBACK;
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    x_return_status := FND_API.G_RET_STS_UNEXP_ERROR;
    x_msg_data      := SQLERRM;
    x_msg_count     := 1;
END CREATE_TASK;

END XX_COLLECTIONS_TASK_PKG;
/
SHOW ERRORS;

GRANT EXECUTE ON APPS.XX_COLLECTIONS_TASK_PKG TO PUBLIC;

-- Verify compilation
SELECT object_name, object_type, status
FROM user_objects
WHERE object_name = 'XX_COLLECTIONS_TASK_PKG'
ORDER BY object_type;

EXIT;
