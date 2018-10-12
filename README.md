# DFSR PowerShell

This module contains functions for monitoring & managing Windows DFSR using PowerShell

These functions build on the existing functionality of the Microsoft DFSR cmdlets and adds further functionality.

Get-StagingQuotaEstimate.ps1 is a script which can help with identifying the top 300 files in a replicated directory, in order to set the staging quota to an appropriate threshold.