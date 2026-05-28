SET FEEDBACK ON
SET SERVEROUTPUT ON

-- ============================================================================
-- XX_COLLECTIONS_REST_PKG - Collections REST API Package
-- Registered with iRep as XxCollectionsRestPkg
-- Provides: credit hold management, collections note creation
-- ============================================================================

CREATE OR REPLACE PACKAGE APPS.XX_COLLECTIONS_REST_PKG AS
/* $Header: XX_COLLECTIONS_REST_PKG.pls 1.1 2026/03/17 00:00:00 applmgr ship $ */
/*#
 * Public API for Oracle EBS Collections operations via ISG REST.
 * Provides credit hold management and collections note creation.
 *
 * @rep:scope public
 * @rep:product AR
 * @rep:displayname Collections REST Services
 * @rep:lifecycle active
 * @rep:compatibility S
 * @rep:category BUSINESS_ENTITY AR_CUSTOMER
 */

/*#
 * Updates the credit hold flag on a customer account profile.
 * Wraps HZ_CUSTOMER_PROFILE_V2PUB.UPDATE_CUSTOMER_PROFILE.
 *
 * @param p_cust_account_profile_id Customer Account Profile ID
 * @param p_cust_account_id Customer Account ID
 * @param p_credit_hold Credit hold flag: Y=hold, N=release
 * @param p_object_version_number Object version number for optimistic locking
 * @param x_return_status Return status: S=Success, E=Error, U=Unexpected
 * @param x_msg_count Number of messages
 * @param x_msg_data Error message text
 * @param x_object_version_number New object version number after update
 * @rep:scope public
 * @rep:lifecycle active
 * @rep:displayname Update Credit Hold
 */
PROCEDURE UPDATE_CREDIT_HOLD(
  p_cust_account_profile_id IN  NUMBER,
  p_cust_account_id         IN  NUMBER,
  p_credit_hold             IN  VARCHAR2,
  p_object_version_number   IN  NUMBER,
  x_return_status           OUT VARCHAR2,
  x_msg_count               OUT NUMBER,
  x_msg_data                OUT VARCHAR2,
  x_object_version_number   OUT NUMBER
);

/*#
 * Creates a collections note linked to a customer account.
 * Wraps JTF_NOTES_PUB.SECURE_CREATE_NOTE with note type mapping.
 * Friendly types (CALL, DUNNING, PROMISE, etc.) are mapped to IEX lookup codes.
 *
 * @param p_source_object_id Customer Account ID (source object)
 * @param p_notes Note text (max 2000 chars)
 * @param p_note_type Note type: CALL, DUNNING, PROMISE, PAYMENT, DISPUTE, ADJUSTMENT, WRITEOFF, BANKRUPTCY, LITIGATION, GENERAL, EMAIL
 * @param x_return_status Return status: S=Success, E=Error, U=Unexpected
 * @param x_jtf_note_id Created note ID
 * @param x_msg_count Number of messages
 * @param x_msg_data Error message text
 * @rep:scope public
 * @rep:lifecycle active
 * @rep:displayname Create Collections Note
 */
PROCEDURE CREATE_COLLECTIONS_NOTE(
  p_source_object_id   IN  NUMBER,
  p_notes              IN  VARCHAR2,
  p_note_type          IN  VARCHAR2,
  x_return_status      OUT VARCHAR2,
  x_jtf_note_id        OUT NUMBER,
  x_msg_count          OUT NUMBER,
  x_msg_data           OUT VARCHAR2
);

/*#
 * Retrieves customer account profile ID and object version number.
 * Used by credit hold operations to resolve required parameters from cust_account_id.
 *
 * @param p_cust_account_id Customer Account ID
 * @param x_cust_account_profile_id Customer Account Profile ID (PK of HZ_CUSTOMER_PROFILES)
 * @param x_object_version_number Object version number for optimistic locking
 * @param x_credit_hold Current credit hold flag (Y/N)
 * @param x_return_status Return status: S=Success, E=Error
 * @param x_msg_data Error message text
 * @rep:scope public
 * @rep:lifecycle active
 * @rep:displayname Get Customer Profile
 */
PROCEDURE GET_CUSTOMER_PROFILE(
  p_cust_account_id           IN  NUMBER,
  x_cust_account_profile_id   OUT NUMBER,
  x_object_version_number     OUT NUMBER,
  x_credit_hold               OUT VARCHAR2,
  x_return_status             OUT VARCHAR2,
  x_msg_data                  OUT VARCHAR2
);

END XX_COLLECTIONS_REST_PKG;
/
SHOW ERRORS;

CREATE OR REPLACE PACKAGE BODY APPS.XX_COLLECTIONS_REST_PKG AS

PROCEDURE UPDATE_CREDIT_HOLD(
  p_cust_account_profile_id IN  NUMBER,
  p_cust_account_id         IN  NUMBER,
  p_credit_hold             IN  VARCHAR2,
  p_object_version_number   IN  NUMBER,
  x_return_status           OUT VARCHAR2,
  x_msg_count               OUT NUMBER,
  x_msg_data                OUT VARCHAR2,
  x_object_version_number   OUT NUMBER
) IS
  l_profile_rec HZ_CUSTOMER_PROFILE_V2PUB.CUSTOMER_PROFILE_REC_TYPE;
  l_ovn         NUMBER := p_object_version_number;
BEGIN
  -- Ensure MO context is set
  IF MO_GLOBAL.GET_CURRENT_ORG_ID IS NULL THEN
    FND_GLOBAL.APPS_INITIALIZE(0, 20678, 222);
    MO_GLOBAL.SET_POLICY_CONTEXT('S', 204);
  END IF;

  l_profile_rec.cust_account_profile_id := p_cust_account_profile_id;
  l_profile_rec.cust_account_id         := p_cust_account_id;
  l_profile_rec.credit_hold             := p_credit_hold;

  HZ_CUSTOMER_PROFILE_V2PUB.UPDATE_CUSTOMER_PROFILE(
    p_init_msg_list         => FND_API.G_TRUE,
    p_customer_profile_rec  => l_profile_rec,
    p_object_version_number => l_ovn,
    x_return_status         => x_return_status,
    x_msg_count             => x_msg_count,
    x_msg_data              => x_msg_data
  );

  x_object_version_number := l_ovn;

  -- Collect all messages if count > 1
  IF x_msg_count > 1 THEN
    DECLARE
      l_msg VARCHAR2(2000);
      l_all VARCHAR2(4000) := '';
    BEGIN
      FOR i IN 1..x_msg_count LOOP
        l_msg := FND_MSG_PUB.GET(p_msg_index => i, p_encoded => FND_API.G_FALSE);
        l_all := l_all || '[' || i || '] ' || NVL(l_msg,'') || ' ';
      END LOOP;
      x_msg_data := SUBSTR(l_all, 1, 2000);
    END;
  END IF;

  IF x_return_status = FND_API.G_RET_STS_SUCCESS THEN
    COMMIT;
  ELSE
    ROLLBACK;
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    x_return_status := FND_API.G_RET_STS_UNEXP_ERROR;
    x_msg_data      := SQLERRM;
    x_msg_count     := 1;
END UPDATE_CREDIT_HOLD;


PROCEDURE CREATE_COLLECTIONS_NOTE(
  p_source_object_id   IN  NUMBER,
  p_notes              IN  VARCHAR2,
  p_note_type          IN  VARCHAR2,
  x_return_status      OUT VARCHAR2,
  x_jtf_note_id        OUT NUMBER,
  x_msg_count          OUT NUMBER,
  x_msg_data           OUT VARCHAR2
) IS
  l_jtf_note_id NUMBER;
  l_jtf_type    VARCHAR2(30);
BEGIN
  -- Ensure apps context
  IF FND_GLOBAL.USER_ID = -1 THEN
    FND_GLOBAL.APPS_INITIALIZE(0, 20678, 222);
  END IF;

  -- Map friendly note type names to valid JTF/IEX lookup codes
  l_jtf_type := CASE UPPER(p_note_type)
    WHEN 'CALL'        THEN 'IEX_ACCOUNT'
    WHEN 'DUNNING'     THEN 'IEX_DUNNING'
    WHEN 'PROMISE'     THEN 'IEX_PROMISE'
    WHEN 'PAYMENT'     THEN 'IEX_PAYMENT'
    WHEN 'DISPUTE'     THEN 'IEX_DISPUTE'
    WHEN 'ADJUSTMENT'  THEN 'IEX_ADJUSTMENT'
    WHEN 'WRITEOFF'    THEN 'IEX_WRITEOFF'
    WHEN 'BANKRUPTCY'  THEN 'IEX_BANKRUPCY'
    WHEN 'LITIGATION'  THEN 'IEX_LITIGATION'
    WHEN 'EMAIL'       THEN 'IEX_ACCOUNT'
    WHEN 'GENERAL'     THEN 'GENERAL'
    ELSE p_note_type
  END;

  JTF_NOTES_PUB.SECURE_CREATE_NOTE(
    p_api_version        => 1.0,
    p_init_msg_list      => FND_API.G_TRUE,
    p_commit             => FND_API.G_TRUE,
    p_source_object_code => 'IEX_ACCOUNT',
    p_source_object_id   => p_source_object_id,
    p_notes              => SUBSTR(p_notes, 1, 2000),
    p_note_type          => l_jtf_type,
    p_entered_by         => FND_GLOBAL.USER_ID,
    p_entered_date       => SYSDATE,
    x_jtf_note_id        => l_jtf_note_id,
    x_return_status      => x_return_status,
    x_msg_count          => x_msg_count,
    x_msg_data           => x_msg_data
  );

  x_jtf_note_id := l_jtf_note_id;

  IF x_msg_count > 1 AND x_return_status != FND_API.G_RET_STS_SUCCESS THEN
    DECLARE
      l_msg VARCHAR2(2000);
      l_all VARCHAR2(4000) := '';
    BEGIN
      FOR i IN 1..x_msg_count LOOP
        l_msg := FND_MSG_PUB.GET(p_msg_index => i, p_encoded => FND_API.G_FALSE);
        l_all := l_all || '[' || i || '] ' || NVL(l_msg,'') || ' ';
      END LOOP;
      x_msg_data := SUBSTR(l_all, 1, 2000);
    END;
  END IF;

EXCEPTION
  WHEN OTHERS THEN
    ROLLBACK;
    x_return_status := FND_API.G_RET_STS_UNEXP_ERROR;
    x_msg_data      := SQLERRM;
    x_msg_count     := 1;
END CREATE_COLLECTIONS_NOTE;


PROCEDURE GET_CUSTOMER_PROFILE(
  p_cust_account_id           IN  NUMBER,
  x_cust_account_profile_id   OUT NUMBER,
  x_object_version_number     OUT NUMBER,
  x_credit_hold               OUT VARCHAR2,
  x_return_status             OUT VARCHAR2,
  x_msg_data                  OUT VARCHAR2
) IS
BEGIN
  SELECT cust_account_profile_id,
         object_version_number,
         NVL(credit_hold, 'N')
  INTO   x_cust_account_profile_id,
         x_object_version_number,
         x_credit_hold
  FROM   hz_customer_profiles
  WHERE  cust_account_id = p_cust_account_id
  AND    site_use_id IS NULL
  AND    ROWNUM = 1;

  x_return_status := 'S';

EXCEPTION
  WHEN NO_DATA_FOUND THEN
    x_return_status := 'E';
    x_msg_data      := 'No profile found for cust_account_id ' || p_cust_account_id;
  WHEN OTHERS THEN
    x_return_status := 'U';
    x_msg_data      := SQLERRM;
END GET_CUSTOMER_PROFILE;

END XX_COLLECTIONS_REST_PKG;
/
SHOW ERRORS;

-- Grant execute to public so ISG REST can call it
GRANT EXECUTE ON APPS.XX_COLLECTIONS_REST_PKG TO PUBLIC;

-- Verify compilation
SELECT object_name, object_type, status
FROM user_objects
WHERE object_name = 'XX_COLLECTIONS_REST_PKG'
ORDER BY object_type;

EXIT;
