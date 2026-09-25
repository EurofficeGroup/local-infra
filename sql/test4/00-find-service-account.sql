/* =====================================================================
   Who needs access to your share?

   RUN ON: vm-tstdb-uks-02.datacentre.euroffice.com

   When you back up to a UNC path, the write is done by the SQL Server
   *service account*, not by you. Your own permissions on the share are
   irrelevant - the account below is the one that must be able to write there.

   Read-only. Touches nothing.
   ===================================================================== */

SELECT servicename,
       service_account,
       startup_type_desc,
       status_desc
  FROM sys.dm_server_services;

/*  What you will see, and what it means for the share:

    'NT Service\MSSQLSERVER'            -> a virtual account. Over the network it
    or 'NT AUTHORITY\SYSTEM'               presents as the COMPUTER account:
    or 'NT AUTHORITY\NETWORK SERVICE'      EUROFFICE\VM-TSTDB-UKS-02$
                                           Grant the share to that name.

    'EUROFFICE\svc-something'           -> a domain service account.
                                           Grant the share to exactly that name.

    Whichever it is, copy it - share-setup.ps1 asks for it.
*/
