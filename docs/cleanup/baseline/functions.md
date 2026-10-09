# Function inventory (P0 baseline)

Generated 2026-10-09 from commit 86f456f by a text scan (script: docs/cleanup/baseline/inventory.js).

Every `function name(` declaration in the office app (`index.html`) and the field app (`field-app/app.js`, `field-app/index.html`), with every line in the same app that mentions the name as a word. The two apps are separate pages, so a name only counts within its own app.

How to read it:

- **Refs** lists `file:line` for each mentioning line (first 15). `idx` = index.html, `app` = field-app/app.js, `fidx` = field-app/index.html, `sw` = field-app/sw.js. A trailing `ʰ` marks a line where the name sits inside an inline `on…=` handler.
- A text scan over-counts: a mention in a comment or a string that is not a call still counts as a ref. It also misses names built at run time (`window['x' + y]`). So **zero refs** means "nothing names it in this app", **not** "safe to delete": P7 checks those across the rest of the repo before anyone proposes a deletion.
- **Indent** is the declaration's leading spaces. Functions nested inside other functions are listed too; indent tells them apart.

## Summary

| | Office | Field |
|---|---|---|
| Function declarations | 819 | 110 |
| Names declared more than once | 1 | 0 |
| Zero refs | 2 | 0 |

## Names declared more than once

Same name declared twice in one app. At top level the later one silently wins; nested ones may be legitimate (a local helper in two different functions). Check each before calling it a bug.

| Name | Declarations (file:line, indent) |
|---|---|
| `filterPastures` | idx:25113 (8), idx:25268 (8) |

## Zero refs (suspects for P7, not a delete list)

| Name | Defined | Indent |
|---|---|---|
| `openEditAssignmentModal` | idx:25776 | 4 |
| `deleteAssignmentRow` | idx:25816 | 4 |

## All functions: office app

| Name | Defined | Refs | Where |
|---|---|---|---|
| `isReadOnlyRole` | idx:6382 | 3 | idx:6405 idx:6414 idx:6427 |
| `readOnlyRefusal` | idx:6388 | 8 | idx:6407 idx:6408 idx:6409 idx:6410 idx:6415 idx:6428 idx:6429 idx:6430 |
| `friendlyDbError` | idx:6480 | 7 | idx:6490 idx:9910 idx:9921 idx:9966 idx:10157 idx:10166 idx:24132 |
| `showAlert` | idx:6488 | 448 | idx:6827 idx:6834 idx:6866 idx:6870 idx:6876 idx:6989 idx:6992 idx:6997 idx:7010 idx:7456 idx:8544 idx:9880 idx:9881 idx:9882 idx:9910 …+433 |
| `clearAlert` | idx:6494 | 99 | idx:6860 idx:6910 idx:6980 idx:9974 idx:10064 idx:10210 idx:10357 idx:12594 idx:13966 idx:15547 idx:17374 idx:17511 idx:22263 idx:22376 idx:22486 …+84 |
| `pdfSafe` | idx:6523 | 3 | idx:6628 idx:6635 idx:6638 |
| `repCellText` | idx:6533 | 2 | idx:6555 idx:6558 |
| `repBlocks` | idx:6545 | 3 | idx:6574 idx:6617 idx:21122 |
| `repMeta` | idx:6568 | 2 | idx:6606 idx:6628 |
| `printReport` | idx:6572 | 2 | idx:6658 idx:17656 |
| `shareReportPdf` | idx:6614 | 2 | idx:6659 idx:17658 |
| `wireReportOutputs` | idx:6656 | 8 | idx:17592 idx:17670 idx:17684 idx:18980 idx:19201 idx:19393 idx:20295 idx:21123 |
| `escapeHtml` | idx:6689 | 767 | idx:6491 idx:6579 idx:6582 idx:6585 idx:6592 idx:6605 idx:6606 idx:6763 idx:6764 idx:6765 idx:6770 idx:6771 idx:6772 idx:6773 idx:6774 …+752 |
| `tagToInt` | idx:6696 | 5 | idx:6692 idx:6744 idx:28716 idx:29111 idx:29671 |
| `normalizeTag` | idx:6703 | 4 | idx:11442 idx:12348 idx:26966 idx:29650 |
| `loadWithdrawalHolds` | idx:6717 | 1 | idx:6751 |
| `withdrawalConfirm` | idx:6750 | 4 | idx:6151 idx:14049 idx:17274 idx:30714 |
| `fmtMoney` | idx:6790 | 182 | idx:7099 idx:7845 idx:8009 idx:8011 idx:8053 idx:8055 idx:9364 idx:9379 idx:9383 idx:9384 idx:9397 idx:9408 idx:9410 idx:9413 idx:9420 …+167 |
| `fmtNum` | idx:6791 | 542 | idx:6762 idx:7093 idx:7094 idx:7095 idx:7096 idx:7097 idx:7145 idx:7149 idx:7150 idx:7152 idx:7153 idx:7738 idx:7739 idx:7742 idx:7748 …+527 |
| `fmtDate` | idx:6798 | 153 | idx:6764 idx:6773 idx:6775 idx:7090 idx:7670 idx:7676 idx:8005 idx:8028 idx:8352 idx:9342 idx:9374 idx:9382 idx:9480 idx:9485 idx:9490 …+138 |
| `showModal` | idx:6815 | 43 | idx:6778 idx:7177 idx:10011 idx:10258 idx:11832 idx:12270 idx:15611 idx:16347 idx:16756 idx:17144 idx:17375 idx:17513 idx:22293 idx:22509 idx:22700 …+28 |
| `hideModal` | idx:6816 | 96 | idx:3681ʰ idx:3723ʰ idx:3747ʰ idx:6783 idx:7169 idx:10061 idx:10129 idx:10353 idx:10460 idx:10478 idx:12029 idx:12317 idx:12392 idx:15854 idx:15872 …+81 |
| `formatSexClass` | idx:6817 | 4 | idx:7092 idx:23080 idx:23132 idx:24941 |
| `checkSession` | idx:6820 | 1 | idx:41105 |
| `onLoggedIn` | idx:6824 | 2 | idx:6822 idx:6873 |
| `showLoginScreen` | idx:6850 | 3 | idx:6822 idx:6833 idx:6889 |
| `userMenuShow` | idx:6879 | 3 | idx:6885 idx:6887 idx:6888 |
| `userSignInLabel` | idx:6898 | 1 | idx:6960 |
| `loadUsers` | idx:6909 | 6 | idx:6987 idx:6989 idx:6991 idx:6996 idx:7046 idx:10580 |
| `applyUserChange` | idx:6979 | 3 | idx:7014 idx:7028 idx:7042 |
| `showLotsList` | idx:7049 | 4 | idx:7457 idx:8145 idx:8545 idx:10525 |
| `loadLots` | idx:7054 | 3 | idx:7052 idx:7186 idx:7188 |
| `loadHeadTieout` | idx:7120 | 2 | idx:7056 idx:7178 |
| `renderHeadTieoutTable` | idx:7141 | 1 | idx:7179 |
| `applyLotPenTabs` | idx:7207 | 2 | idx:7233 idx:7464 |
| `showLotSubtab` | idx:7220 | 14 | idx:1223 idx:7203 idx:7204 idx:7270 idx:7271 idx:7287 idx:7303 idx:7359 idx:7368 idx:7383 idx:7464 idx:7465 idx:8122 idx:16861 |
| `lotDrill` | idx:7261 | 2 | idx:7340 idx:7780 |
| `drillBackSet` | idx:7311 | 2 | idx:7275 idx:7278 |
| `drillBackClear` | idx:7320 | 3 | idx:7328 idx:10512 idx:19403 |
| `refreshLotTabCounts` | idx:7345 | 1 | idx:8130 |
| `showLotDetail` | idx:7373 | 43 | idx:7114 idx:7170 idx:7194 idx:7203 idx:7331 idx:7333 idx:9970 idx:10133 idx:10183 idx:10463 idx:10481 idx:16546 idx:16673 idx:16691 idx:17302 …+28 |
| `buildTileRows` | idx:7781 | 7 | idx:7899 idx:7903 idx:7907 idx:7911 idx:7960 idx:7964 idx:7968 |
| `bindKebab` | idx:8150 | 3 | idx:8168 idx:8169 idx:34985 |
| `maybeCompressImage` | idx:8235 | 1 | idx:8282 |
| `uploadAttachment` | idx:8278 | 3 | idx:8428 idx:8480 idx:38174 |
| `deleteAttachment` | idx:8315 | 1 | idx:8381 |
| `getAttachmentUrl` | idx:8325 | 1 | idx:8365 |
| `renderAttachmentList` | idx:8337 | 2 | idx:8401 idx:8453 |
| `loadInvoiceAttachments` | idx:8391 | 3 | idx:8403 idx:8437 idx:10248 |
| `loadReceiptAttachments` | idx:8443 | 3 | idx:8455 idx:8489 idx:27601 |
| `toggleCloseoutMed` | idx:8587 | 1 | idx:7281 |
| `setCloseoutView` | idx:8592 | 1 | idx:8601 |
| `closeoutRates` | idx:8604 | 3 | idx:9309 idx:9870 idx:9938 |
| `interestOn` | idx:8633 | 3 | idx:8892 idx:9088 idx:9185 |
| `daysBetween` | idx:8639 | 14 | idx:8724 idx:8859 idx:8913 idx:9000 idx:9216 idx:9280 idx:9315 idx:9334 idx:9682 idx:9877 idx:18009 idx:18110 idx:18127 idx:18516 |
| `chicagoDayOf` | idx:8651 | 1 | idx:11042 |
| `addDaysIso` | idx:8660 | 3 | idx:11042 idx:39420 idx:39512 |
| `ranchToday` | idx:8667 | 100 | idx:6569 idx:6592 idx:6650 idx:7449 idx:8692 idx:8724 idx:8913 idx:8999 idx:9216 idx:9334 idx:9373 idx:9671 idx:9979 idx:10049 idx:10164 …+85 |
| `loadRanchSettings` | idx:8676 | 2 | idx:7557 idx:24261 |
| `ranchNonFeedRateOn` | idx:8701 | 2 | idx:7594 idx:8692 |
| `ranchNonFeedLatest` | idx:8707 | 3 | idx:8821 idx:9373 idx:9374 |
| `closeoutActual` | idx:8715 | 2 | idx:9327 idx:16138 |
| `assumedTotalDeathsLeft` | idx:8993 | 2 | idx:9689 idx:9772 |
| `closeoutProjection` | idx:8998 | 1 | idx:9351 |
| `closeoutBudget` | idx:9152 | 1 | idx:9352 |
| `renderCloseoutCalculator` | idx:9202 | 3 | idx:8109 idx:8117 idx:9935 |
| `recalculate` | idx:9306 | 10 | idx:8590 idx:8595 idx:9210 idx:9285 idx:9294 idx:9298 idx:9303 idx:9349 idx:9913 idx:9929 |
| `renderBudgetBox` | idx:9835 | 1 | idx:9319 |
| `freezeLotBudget` | idx:9869 | 1 | idx:9865 |
| `deleteLotBudget` | idx:9916 | 1 | idx:9853 |
| `openLotModal` | idx:9973 | 4 | idx:8494 idx:10058 idx:10059 idx:10060 |
| `syncLotEstWeightRequired` | idx:10028 | 2 | idx:10010 idx:10047 |
| `saleHasNoTicketMark` | idx:10145 | 3 | idx:8927 idx:10151 idx:18158 |
| `lotUnweighedSales` | idx:10146 | 1 | idx:10156 |
| `closeLotGuard` | idx:10155 | 4 | idx:10177 idx:14301 idx:27061 idx:30818 |
| `lotDefaultProtocolId` | idx:10191 | 2 | idx:10251 idx:27604 |
| `openInvoiceModal` | idx:10208 | 2 | idx:8082 idx:10352 |
| `renderInvoiceReconcile` | idx:10264 | 1 | idx:10243 |
| `updateInvoiceReconcileSummary` | idx:10332 | 4 | idx:10293 idx:10325 idx:10329 idx:10348 |
| `hideAllViews` | idx:10488 | 14 | idx:10522 idx:10529 idx:10553 idx:12524 idx:13017 idx:13958 idx:14310 idx:14401 idx:14660 idx:15471 idx:31246 idx:36753 idx:37617 idx:38835 |
| `clearAllNavActive` | idx:10511 | 13 | idx:7308 idx:10523 idx:10530 idx:10554 idx:12525 idx:13018 idx:13959 idx:14311 idx:14402 idx:14661 idx:15472 idx:31247 idx:36754 |
| `showLotsTab` | idx:10521 | 5 | idx:6846 idx:7332 idx:15885 idx:19404 idx:38129 |
| `showAnimalHealthTab` | idx:10528 | 3 | idx:13066 idx:15886 idx:16049 |
| `showSettingsTab` | idx:10552 | 6 | idx:9392 idx:13067 idx:13068 idx:15887 idx:16053 idx:18626 |
| `tagSortKey` | idx:10597 | 1 | idx:10604 |
| `compareTags` | idx:10603 | 3 | idx:11210 idx:11272 idx:20627 |
| `entryDayKey` | idx:10615 | 10 | idx:11209 idx:11218 idx:11221 idx:11321 idx:11359 idx:11502 idx:11529 idx:11549 idx:11574 idx:12409 |
| `formatDayHeading` | idx:10624 | 1 | idx:11223 |
| `loadApprovalLookups` | idx:10637 | 1 | idx:11110 |
| `approvalOverride` | idx:10691 | 3 | idx:10736 idx:11057 idx:12467 |
| `resolveApprovalEntry` | idx:10734 | 3 | idx:11114 idx:11547 idx:12058 |
| `flagDuplicateApprovals` | idx:11078 | 1 | idx:11115 |
| `loadApprovals` | idx:11097 | 12 | idx:11719 idx:11732 idx:11750 idx:11754 idx:12319 idx:12394 idx:12446 idx:12450 idx:12500 idx:12520 idx:12529 idx:15894 |
| `updateApprovalsBadge` | idx:11126 | 5 | idx:11118 idx:11135 idx:11159 idx:38018 idx:38245 |
| `updatePbBadge` | idx:11135 | 1 | idx:12632 |
| `apprRefreshCounts` | idx:11140 | 4 | idx:6848 idx:15895 idx:15907 idx:38193 |
| `renderApprovals` | idx:11162 | 1 | idx:11117 |
| `approvalRowHtml` | idx:11286 | 3 | idx:11211 idx:11251 idx:11273 |
| `apprFixPastureHtml` | idx:11382 | 1 | idx:11374 |
| `apprPlaceLabel` | idx:11405 | 4 | idx:11391 idx:11397 idx:11417 idx:12514 |
| `apprPlaceOptions` | idx:11410 | 2 | idx:11206 idx:11402 |
| `approvalNoteFor` | idx:11432 | 1 | idx:11713 |
| `postDoctoringEntry` | idx:11437 | 1 | idx:11696 |
| `postDeathEntry` | idx:11486 | 1 | idx:11692 |
| `postMoveEntry` | idx:11514 | 1 | idx:11693 |
| `postCountEntry` | idx:11548 | 1 | idx:11694 |
| `postWeightEntry` | idx:11573 | 1 | idx:11695 |
| `rollbackPosted` | idx:11609 | 1 | idx:11721 |
| `approveSelected` | idx:11644 | 1 | idx:15931 |
| `rejectApprovalEntry` | idx:11736 | 1 | idx:15976 |
| `openSettlePasture` | idx:11783 | 2 | idx:18427 idx:24968 |
| `settleCounterpartyOptions` | idx:11835 | 1 | idx:11899 |
| `renderSettleRows` | idx:11852 | 2 | idx:11831 idx:15929 |
| `settleRowValues` | idx:11875 | 2 | idx:11885 idx:11945 |
| `recomputeSettle` | idx:11883 | 2 | idx:11870 idx:11872 |
| `saveSettlePasture` | idx:11942 | 1 | idx:15919 |
| `apprPastureOptions` | idx:12066 | 5 | idx:12124 idx:12169 idx:12177 idx:12213 idx:12233 |
| `apprRanchOptions` | idx:12074 | 4 | idx:12122 idx:12167 idx:12175 idx:12211 |
| `apprLotOptionsForPasture` | idx:12082 | 4 | idx:12129 idx:12171 idx:12234 idx:12237 |
| `apprLotOptionsAll` | idx:12095 | 1 | idx:12209 |
| `openApprovalEdit` | idx:12100 | 1 | idx:15961 |
| `saveApprovalEdit` | idx:12273 | 1 | idx:15918 |
| `saveApprovalDate` | idx:12400 | 1 | idx:15944 |
| `saveApprovalNote` | idx:12455 | 1 | idx:15996 |
| `apprFixPastures` | idx:12470 | 4 | idx:15948 idx:15956 idx:15965 idx:15972 |
| `apprKeepPasture` | idx:12506 | 1 | idx:15963 |
| `showApprovalsTab` | idx:12523 | 3 | idx:15889 idx:27757 idx:38431 |
| `pbRoleNow` | idx:12562 | 3 | idx:12563 idx:12564 idx:12565 |
| `apprCanFeed` | idx:12563 | 6 | idx:11146 idx:12530 idx:12575 idx:12577 idx:12582 idx:12600 |
| `pbCanWrite` | idx:12564 | 3 | idx:12824 idx:38026 idx:38250 |
| `pbIsOwner` | idx:12565 | 2 | idx:12839 idx:12989 |
| `pbLoadRole` | idx:12567 | 2 | idx:11142 idx:12596 |
| `showApprovalsPane` | idx:12581 | 3 | idx:12528 idx:12577 idx:15911 |
| `loadPbReports` | idx:12593 | 3 | idx:12530 idx:12937 idx:15893 |
| `pbMissingDays` | idx:12648 | 1 | idx:12668 |
| `pbReadBarHtml` | idx:12665 | 1 | idx:12880 |
| `pbWaitingHtml` | idx:12680 | 1 | idx:12881 |
| `pbPastureSelect` | idx:12690 | 2 | idx:12755 idx:12765 |
| `pbIsOpen` | idx:12699 | 10 | idx:12741 idx:12753 idx:12759 idx:12836 idx:12843 idx:12957 idx:12959 idx:12961 idx:12962 idx:12969 |
| `pbChip` | idx:12703 | 2 | idx:12852 idx:12872 |
| `pbPensHtml` | idx:12709 | 1 | idx:12859 |
| `pbIngredientsHtml` | idx:12782 | 1 | idx:12860 |
| `pbChargesHtml` | idx:12794 | 1 | idx:12861 |
| `pbCardHtml` | idx:12821 | 1 | idx:12891 |
| `pbMiniHtml` | idx:12869 | 1 | idx:12891 |
| `renderPbReports` | idx:12879 | 4 | idx:12633 idx:12927 idx:12933 idx:13011 |
| `pbSplitRefresh` | idx:12898 | 4 | idx:12893 idx:13001 idx:15916 idx:15917 |
| `pbRun` | idx:12923 | 8 | idx:12967 idx:12973 idx:12977 idx:12981 idx:12986 idx:12991 idx:12997 idx:13006 |
| `pbOnClick` | idx:12948 | 1 | idx:15913 |
| `showReportsTab` | idx:13016 | 4 | idx:7274 idx:7645 idx:15888 idx:16058 |
| `showMedsTab` | idx:13066 | 1 | idx:13065 |
| `showProtocolsTab` | idx:13067 | 3 | idx:13065 idx:23118 idx:23205 |
| `showLocationsTab` | idx:13068 | 6 | idx:13065 idx:24359 idx:24469 idx:24849 idx:24963 idx:25612 |
| `shpTempId` | idx:13099 | 8 | idx:13644 idx:13679 idx:13682 idx:13970 idx:13975 idx:13976 idx:14589 idx:14597 |
| `shpNum` | idx:13101 | 44 | idx:13139 idx:13140 idx:13147 idx:13148 idx:13149 idx:13150 idx:13176 idx:13179 idx:13184 idx:13185 idx:13199 idx:13230 idx:13307 idx:13308 idx:13319 …+29 |
| `round2` | idx:13106 | 47 | idx:13177 idx:13186 idx:13194 idx:13195 idx:13203 idx:13204 idx:13207 idx:13270 idx:13754 idx:13761 idx:14069 idx:14170 idx:14182 idx:14203 idx:14204 …+32 |
| `allocateProportional` | idx:13115 | 10 | idx:13229 idx:13255 idx:13262 idx:13263 idx:13264 idx:13265 idx:15655 idx:15656 idx:15657 idx:15658 |
| `shpLineHead` | idx:13138 | 3 | idx:13143 idx:13224 idx:13439 |
| `shpLoadLinesHead` | idx:13142 | 2 | idx:13318 idx:13780 |
| `shpGroupTotals` | idx:13146 | 6 | idx:13164 idx:13254 idx:13326 idx:13489 idx:13788 idx:14089 |
| `shpTotals` | idx:13163 | 1 | idx:13183 |
| `shpDeductionAmount` | idx:13171 | 6 | idx:13191 idx:13859 idx:14142 idx:15631 idx:15736 idx:15819 |
| `shpSettlement` | idx:13182 | 4 | idx:13217 idx:13295 idx:13757 idx:14029 |
| `shpAllocate` | idx:13216 | 3 | idx:13297 idx:13764 idx:14031 |
| `shpPastureDraw` | idx:13276 | 2 | idx:13338 idx:14216 |
| `shpValidate` | idx:13293 | 2 | idx:13878 idx:14026 |
| `shpLotOptions` | idx:13363 | 3 | idx:13463 idx:13590 idx:13671 |
| `shpPastureOptions` | idx:13391 | 3 | idx:13466 idx:13591 idx:13672 |
| `shpPairExists` | idx:13423 | 2 | idx:13599 idx:13617 |
| `shpDrawnByPair` | idx:13432 | 3 | idx:13364 idx:13392 idx:13822 |
| `shpAvailLabel` | idx:13450 | 6 | idx:13387 idx:13402 idx:13417 idx:15106 idx:15117 idx:15132 |
| `renderLoadLines` | idx:13456 | 1 | idx:13510 |
| `renderWeightGroups` | idx:13480 | 9 | idx:13630 idx:13634 idx:13645 idx:13650 idx:13654 idx:13995 idx:14012 idx:14594 idx:14614 |
| `wireWeightGroupInputs` | idx:13557 | 1 | idx:13550 |
| `rewireLinePair` | idx:13587 | 2 | idx:13608 idx:13620 |
| `refreshLinePickerLabels` | idx:13664 | 1 | idx:13816 |
| `shpNewLoad` | idx:13677 | 3 | idx:13629 idx:13971 idx:14592 |
| `renderDeductions` | idx:13686 | 4 | idx:13734 idx:13738 idx:13996 idx:14598 |
| `recomputeShipment` | idx:13745 | 17 | idx:13484 idx:13551 idx:13562 idx:13565 idx:13568 idx:13571 idx:13574 idx:13577 idx:13580 idx:13609 idx:13621 idx:13690 idx:13726 idx:13730 idx:13741 …+2 |
| `loadOpenPastureInventory` | idx:13901 | 6 | idx:13946 idx:15412 idx:16215 idx:17111 idx:26556 idx:26574 |
| `loadShipmentInventory` | idx:13945 | 1 | idx:13994 |
| `openShipmentEntry` | idx:13957 | 2 | idx:14007 idx:14580 |
| `openShipmentForLot` | idx:14004 | 1 | idx:1479ʰ |
| `saveShipment` | idx:14025 | 1 | idx:14583 |
| `offerToCloseEmptiedLots` | idx:14290 | 1 | idx:14252 |
| `showSalesTab` | idx:14309 | 5 | idx:14253 idx:14571 idx:14581 idx:14582 idx:15013 |
| `loadShipmentList` | idx:14321 | 2 | idx:14318 idx:14525 |
| `showShipmentDetail` | idx:14386 | 3 | idx:14381 idx:15857 idx:30253 |
| `deleteShipment` | idx:14545 | 1 | idx:14538 |
| `acctLoadConstants` | idx:14638 | 1 | idx:14669 |
| `acctSaveConstants` | idx:14650 | 1 | idx:15024 |
| `showSalesReportTab` | idx:14659 | 2 | idx:14530 idx:15011 |
| `loadAcctReport` | idx:14698 | 3 | idx:14534 idx:14695 idx:15022 |
| `acctConstants` | idx:14752 | 4 | idx:14813 idx:14885 idx:14945 idx:14993 |
| `acctRowCells` | idx:14767 | 5 | idx:14848 idx:14893 idx:14969 idx:14995 idx:16730 |
| `acctTotals` | idx:14784 | 3 | idx:14814 idx:14886 idx:14946 |
| `acctHeaderLines` | idx:14792 | 3 | idx:14836 idx:14891 idx:14960 |
| `renderAcctReport` | idx:14810 | 2 | idx:14749 idx:15024 |
| `acctFilename` | idx:14865 | 2 | idx:14897 idx:14985 |
| `acctNeedYear` | idx:14874 | 3 | idx:14883 idx:14942 idx:14992 |
| `acctPrint` | idx:14881 | 1 | idx:15026 |
| `acctPdf` | idx:14940 | 1 | idx:15027 |
| `acctCopy` | idx:14990 | 1 | idx:15028 |
| `showMovesSalesSub` | idx:15010 | 2 | idx:14578 idx:15020 |
| `mvTempId` | idx:15052 | 1 | idx:15056 |
| `mvNewTicket` | idx:15054 | 3 | idx:15484 idx:15495 idx:15504 |
| `mvDrawnByPair` | idx:15066 | 4 | idx:15087 idx:15110 idx:15279 idx:15296 |
| `mvPairExists` | idx:15079 | 2 | idx:15213 idx:15227 |
| `mvLotOptions` | idx:15086 | 2 | idx:15183 idx:15251 |
| `mvFromPastureOptions` | idx:15109 | 2 | idx:15185 idx:15252 |
| `mvToPastureOptions` | idx:15139 | 1 | idx:15190 |
| `renderMoveTickets` | idx:15161 | 10 | idx:15222 idx:15232 idx:15236 idx:15387 idx:15406 idx:15485 idx:15499 idx:15505 idx:15510 idx:15518 |
| `refreshMoveTicketLabels` | idx:15245 | 1 | idx:15294 |
| `mvValidate` | idx:15257 | 2 | idx:15326 idx:15347 |
| `recomputeMoves` | idx:15292 | 5 | idx:15165 idx:15199 idx:15202 idx:15205 idx:15239 |
| `saveMoves` | idx:15346 | 1 | idx:15507 |
| `loadMoveInventory` | idx:15411 | 4 | idx:15386 idx:15405 idx:15483 idx:15509 |
| `loadRecentMoves` | idx:15432 | 3 | idx:15388 idx:15486 idx:15511 |
| `showMovesTab` | idx:15470 | 1 | idx:15014 |
| `openShipmentMoneyEdit` | idx:15546 | 1 | idx:14527 |
| `smTotals` | idx:15614 | 1 | idx:15623 |
| `smSettlement` | idx:15622 | 3 | idx:15651 idx:15728 idx:15776 |
| `smAllocate` | idx:15650 | 1 | idx:15777 |
| `renderSmDeductions` | idx:15666 | 4 | idx:15610 idx:15708 idx:15711 idx:15876 |
| `recomputeSm` | idx:15717 | 6 | idx:15670 idx:15702 idx:15705 idx:15714 idx:15880 idx:15881 |
| `saveShipmentMoney` | idx:15774 | 1 | idx:15873 |
| `refreshApprovalSelection` | idx:15933 | 3 | idx:11283 idx:15942 idx:15985 |
| `subGroupsClose` | idx:16006 | 2 | idx:16017 idx:16035 |
| `subGroupToggle` | idx:16012 | 2 | idx:16056 idx:34977 |
| `subGroupsRelabel` | idx:16025 | 2 | idx:13025 idx:31268 |
| `isTestLot` | idx:16067 | 5 | idx:7619 idx:7621 idx:19018 idx:19047 idx:19114 |
| `ltStoredRates` | idx:16115 | 1 | idx:16138 |
| `ltComputeBasis` | idx:16135 | 2 | idx:16235 idx:16648 |
| `openLotTransfer` | idx:16161 | 3 | idx:8216 idx:8217 idx:8218 |
| `ltDestPastureOptions` | idx:16354 | 1 | idx:16406 |
| `ltRenderLines` | idx:16368 | 3 | idx:16346 idx:16395 idx:16841 |
| `ltRecompute` | idx:16404 | 8 | idx:16382 idx:16386 idx:16391 idx:16398 idx:16843 idx:16844 idx:16845 idx:16846 |
| `ltValidate` | idx:16464 | 2 | idx:16439 idx:16501 |
| `ltSave` | idx:16500 | 1 | idx:16836 |
| `renderLotTransfers` | idx:16550 | 1 | idx:8118 |
| `recomputeTransferBasis` | idx:16644 | 1 | idx:16633 |
| `deleteLotTransfer` | idx:16679 | 1 | idx:16631 |
| `xpConstants` | idx:16704 | 4 | idx:16715 idx:16761 idx:16792 idx:16807 |
| `xpLoadConstants` | idx:16707 | 1 | idx:16754 |
| `xpSaveConstants` | idx:16714 | 2 | idx:16852 idx:16853 |
| `xpRows` | idx:16719 | 5 | idx:5708 idx:16761 idx:16780 idx:16794 idx:16807 |
| `acctPostingCells` | idx:16733 | 5 | idx:16784 idx:16794 idx:16810 idx:17491 idx:17520 |
| `openTransferPosting` | idx:16750 | 1 | idx:16629 |
| `renderTransferPosting` | idx:16759 | 3 | idx:16755 idx:16852 idx:16853 |
| `xpCopy` | idx:16790 | 1 | idx:16850 |
| `xpPrint` | idx:16805 | 1 | idx:16851 |
| `fpLoad` | idx:16904 | 3 | idx:16931 idx:17125 idx:17625 |
| `loadFeedPen` | idx:16926 | 1 | idx:7255 |
| `fpRenderSummary` | idx:16955 | 2 | idx:16940 idx:17637 |
| `fpRenderSources` | idx:16996 | 2 | idx:16941 idx:17639 |
| `fpRenderRemovals` | idx:17062 | 3 | idx:16942 idx:17631 idx:17641 |
| `openFeedPenRemoval` | idx:17104 | 1 | idx:17649 |
| `fprMethodChanged` | idx:17147 | 2 | idx:17142 idx:17667 |
| `fprSpreadFromTotal` | idx:17158 | 2 | idx:17188 idx:17668 |
| `fprPaintLines` | idx:17167 | 1 | idx:17163 |
| `fprRenderLines` | idx:17173 | 1 | idx:17143 |
| `fprSpread` | idx:17201 | 1 | idx:17161 |
| `fprRecompute` | idx:17214 | 5 | idx:17151 idx:17164 idx:17191 idx:17194 idx:17669 |
| `fprValidate` | idx:17236 | 1 | idx:17259 |
| `fprSave` | idx:17258 | 1 | idx:17666 |
| `fpDeleteRemoval` | idx:17309 | 1 | idx:17677 |
| `openFeedPenFound` | idx:17326 | 1 | idx:17650 |
| `fpoSave` | idx:17378 | 1 | idx:17663 |
| `fppConstants` | idx:17417 | 3 | idx:17433 idx:17450 idx:17518 |
| `fppLoadConstants` | idx:17424 | 1 | idx:17510 |
| `fppSaveConstants` | idx:17432 | 1 | idx:17661 |
| `fppRows` | idx:17439 | 2 | idx:17450 idx:17520 |
| `renderFeedPenPosting` | idx:17448 | 2 | idx:17512 idx:17661 |
| `openFeedPenPosting` | idx:17497 | 1 | idx:17651 |
| `fppCopy` | idx:17516 | 1 | idx:17653 |
| `fpCloseYear` | idx:17537 | 1 | idx:17664 |
| `initFeedPenReport` | idx:17588 | 1 | idx:13040 |
| `renderFeedPenReport` | idx:17620 | 4 | idx:17315 idx:17590 idx:17591 idx:17617 |
| `loadAnomaliesReport` | idx:17681 | 4 | idx:12034 idx:12035 idx:13037 idx:17683 |
| `loadYardSheetReport` | idx:18431 | 2 | idx:13034 idx:18447 |
| `ysFillPickers` | idx:18469 | 1 | idx:18463 |
| `fetchOpenAssignmentRows` | idx:18479 | 4 | idx:18456 idx:18991 idx:19184 idx:19210 |
| `ysFillPastureOptions` | idx:18546 | 3 | idx:18436 idx:18443 idx:18473 |
| `ysFilteredRows` | idx:18558 | 3 | idx:18635 idx:18721 idx:18766 |
| `lotSplitTable` | idx:18586 | 2 | idx:18690 idx:19317 |
| `ysFlagBadge` | idx:18606 | 2 | idx:18661 idx:19317 |
| `pickedValues` | idx:18614 | 14 | idx:18547 idx:18560 idx:18561 idx:18562 idx:18619 idx:18636 idx:19024 idx:19036 idx:19037 idx:19038 idx:19229 idx:19239 idx:19240 idx:19241 |
| `fillPicker` | idx:18617 | 9 | idx:18471 idx:18472 idx:18553 idx:19007 idx:19020 idx:19030 idx:19221 idx:19222 idx:19234 |
| `openPastureFromReport` | idx:18625 | 2 | idx:18713 idx:19355 |
| `headSplitButton` | idx:18630 | 2 | idx:18686 idx:19314 |
| `renderYardSheet` | idx:18634 | 5 | idx:7651 idx:18437 idx:18444 idx:18464 idx:18709 |
| `exportYardSheetCsv` | idx:18720 | 1 | idx:18446 |
| `ysSheetModel` | idx:18765 | 2 | idx:18819 idx:18903 |
| `ysFilterSummary` | idx:18802 | 2 | idx:18874 idx:18913 |
| `printYardSheet` | idx:18818 | 1 | idx:18448 |
| `shareYardSheetPdf` | idx:18901 | 1 | idx:18449 |
| `loadActiveLotsReport` | idx:18965 | 2 | idx:13028 idx:18979 |
| `alFillLotOptions` | idx:19014 | 2 | idx:18970 idx:19006 |
| `alFillPastureOptions` | idx:19023 | 3 | idx:18969 idx:18976 idx:19008 |
| `renderActiveLotsReport` | idx:19033 | 4 | idx:18971 idx:18977 idx:19009 idx:19167 |
| `loadPastureUtilizationReport` | idx:19187 | 2 | idx:13043 idx:19200 |
| `puFillPastureOptions` | idx:19228 | 3 | idx:19191 idx:19197 idx:19223 |
| `renderPastureUtilization` | idx:19237 | 5 | idx:19192 idx:19198 idx:19225 idx:19344 idx:19351 |
| `initProcessingReport` | idx:19369 | 1 | idx:13052 |
| `initHealthCurvesReport` | idx:19428 | 1 | idx:13058 |
| `loadHealthCurvesReport` | idx:19440 | 6 | idx:19431 idx:19437 idx:19556 idx:19562 idx:19632 idx:19661 |
| `hcPct` | idx:19477 | 1 | idx:19489 |
| `hcDelta` | idx:19478 | 1 | idx:19489 |
| `renderHcLots` | idx:19485 | 2 | idx:19432 idx:19469 |
| `renderHcReview` | idx:19509 | 1 | idx:19470 |
| `renderHcBaseline` | idx:19567 | 2 | idx:19433 idx:19471 |
| `renderHcEstimates` | idx:19599 | 3 | idx:19434 idx:19435 idx:19472 |
| `renderHcThresholds` | idx:19636 | 1 | idx:19473 |
| `renderHcExcluded` | idx:19665 | 1 | idx:19474 |
| `initDeathCaptureReport` | idx:19685 | 1 | idx:13061 |
| `loadDeathCaptureReport` | idx:19696 | 2 | idx:19688 idx:19693 |
| `dcVisible` | idx:19705 | 3 | idx:19717 idx:19736 idx:19767 |
| `dcMonth` | idx:19709 | 1 | idx:19711 |
| `dcCells` | idx:19710 | 3 | idx:19720 idx:19741 idx:19780 |
| `renderDeathCapture` | idx:19716 | 2 | idx:19689 idx:19702 |
| `printDeathCapture` | idx:19735 | 1 | idx:19690 |
| `shareDeathCapturePdf` | idx:19766 | 1 | idx:19691 |
| `initFreshCattleReport` | idx:19794 | 1 | idx:13049 |
| `freshTagRange` | idx:19807 | 3 | idx:19862 idx:19904 idx:19959 |
| `loadFreshCattleReport` | idx:19816 | 2 | idx:19797 idx:19801 |
| `shareFreshCattlePdf` | idx:19884 | 1 | idx:19799 |
| `printFreshCattleReport` | idx:19941 | 1 | idx:19798 |
| `loadProcessingReport` | idx:19992 | 3 | idx:19391 idx:19392 idx:19414 |
| `loadDeathAnalysisReport` | idx:20102 | 3 | idx:13046 idx:20299 idx:20300 |
| `dfrLocalDay` | idx:20338 | 5 | idx:20491 idx:20546 idx:20969 idx:20977 idx:20982 |
| `dfrDayBounds` | idx:20343 | 1 | idx:20393 |
| `dfrLongDate` | idx:20350 | 7 | idx:20654 idx:20740 idx:20834 idx:20850 idx:20868 idx:20940 idx:20946 |
| `dfrAscii` | idx:20359 | 3 | idx:20732 idx:20780 idx:20866 |
| `loadDailyReport` | idx:20380 | 5 | idx:20970 idx:20978 idx:20983 idx:20985 idx:20992 |
| `dfrNormalizeAll` | idx:20503 | 2 | idx:20482 idx:20483 |
| `dfrWho` | idx:20516 | 3 | idx:20548 idx:20574 idx:20600 |
| `dfrFromField` | idx:20520 | 3 | idx:20549 idx:20575 idx:20601 |
| `dfrNormalizeDoctoring` | idx:20526 | 1 | idx:20505 |
| `dfrNormalizeMove` | idx:20555 | 1 | idx:20506 |
| `dfrNormalizeDeath` | idx:20581 | 1 | idx:20507 |
| `dfrGroup` | idx:20614 | 7 | idx:20652 idx:20673 idx:20743 idx:20770 idx:20798 idx:20877 idx:20919 |
| `renderDailyReport` | idx:20634 | 1 | idx:20495 |
| `dfrDetailLine` | idx:20701 | 2 | idx:20810 idx:20891 |
| `dfrWhenLabel` | idx:20709 | 3 | idx:20724 idx:20811 idx:20892 |
| `dfrRowHtml` | idx:20714 | 2 | idx:20662 idx:20679 |
| `buildDailyReportText` | idx:20734 | 2 | idx:20947 idx:20954 |
| `dfrRequireModel` | idx:20783 | 4 | idx:20792 idx:20937 idx:20944 idx:20952 |
| `printDailyReport` | idx:20791 | 1 | idx:20986 |
| `buildDailyReportPdf` | idx:20859 | 1 | idx:20939 |
| `shareDailyReportPdf` | idx:20936 | 1 | idx:20987 |
| `emailDailyReport` | idx:20943 | 1 | idx:20988 |
| `copyDailyReportText` | idx:20951 | 1 | idx:20989 |
| `dfrShiftDay` | idx:20965 | 2 | idx:20979 idx:20980 |
| `initDailyReport` | idx:20973 | 1 | idx:13031 |
| `initDoctoringReport` | idx:21050 | 1 | idx:13055 |
| `applyDatePreset` | idx:21140 | 1 | idx:21132 |
| `resetDoctoringFilters` | idx:21170 | 1 | idx:21118 |
| `runDoctoringReport` | idx:21183 | 4 | idx:21117 idx:21137 idx:21167 idx:21180 |
| `docProtocolKey` | idx:21320 | 3 | idx:21228 idx:21298 idx:21331 |
| `docProtocolLabel` | idx:21330 | 5 | idx:21666 idx:21678 idx:22018 idx:22039 idx:22137 |
| `docProtocolKeyLabel` | idx:21337 | 2 | idx:21331 idx:21686 |
| `renderDoctoringSummary` | idx:21354 | 1 | idx:21309 |
| `docDaysBetween` | idx:21510 | 2 | idx:21447 idx:21653 |
| `renderDoctoringComparison` | idx:21525 | 3 | idx:21128 idx:21310 idx:21622 |
| `buildCohortComparison` | idx:21628 | 1 | idx:21544 |
| `buildEventComparison` | idx:21749 | 1 | idx:21544 |
| `renderDoctoringChartShell` | idx:21845 | 1 | idx:21311 |
| `renderDoctoringCharts` | idx:21863 | 1 | idx:21312 |
| `renderDocEventTable` | idx:22008 | 3 | idx:21314 idx:21999 idx:22095 |
| `docCsvEscape` | idx:22103 | 4 | idx:22144 idx:22155 idx:22156 idx:22161 |
| `docDownloadCsv` | idx:22108 | 2 | idx:22146 idx:22165 |
| `exportDoctoringReportCsv` | idx:22120 | 1 | idx:21119 |
| `exportDoctoringComparisonCsv` | idx:22149 | 1 | idx:21124 |
| `loadMeds` | idx:22171 | 3 | idx:10539 idx:22247 idx:22421 |
| `openMedModal` | idx:22262 | 3 | idx:22243 idx:22363 idx:38390 |
| `updateMedCostPerUnit` | idx:22297 | 4 | idx:22285 idx:22367 idx:22368 idx:22369 |
| `updateMedDoseUI` | idx:22313 | 2 | idx:22292 idx:22365 |
| `updateMedPreview` | idx:22346 | 3 | idx:22343 idx:22371 idx:23014 |
| `loadFieldActions` | idx:22432 | 4 | idx:10568 idx:22514 idx:22545 idx:22564 |
| `openFieldActionModal` | idx:22485 | 2 | idx:22480 idx:22512 |
| `loadFieldProtocols` | idx:22572 | 4 | idx:10571 idx:22705 idx:22742 idx:22761 |
| `openFieldProtocolModal` | idx:22648 | 2 | idx:22643 idx:22703 |
| `loadDataTools` | idx:22767 | 2 | idx:10577 idx:22897 |
| `loadTestLotsPreview` | idx:22773 | 1 | idx:22768 |
| `loadMissingInvoices` | idx:22905 | 1 | idx:22769 |
| `loadLegacyRecords` | idx:22947 | 1 | idx:22770 |
| `refreshMedsCache` | idx:22997 | 2 | idx:23005 idx:23226 |
| `ceilTo` | idx:23020 | 4 | idx:22357 idx:23013 idx:23035 idx:23048 |
| `computeDose` | idx:23025 | 3 | idx:23165 idx:23408 idx:28628 |
| `loadProtocols` | idx:23054 | 2 | idx:10562 idx:23101 |
| `showProtocolDetail` | idx:23104 | 3 | idx:23097 idx:23220 idx:23932 |
| `renderProtocolMedsAndSteps` | idx:23156 | 3 | idx:23150 idx:23152 idx:23153 |
| `openProtocolModal` | idx:23224 | 3 | idx:23835 idx:23837 idx:23840 |
| `renderProtoFormMeds` | idx:23279 | 6 | idx:23274 idx:23313 idx:23322 idx:23334 idx:23393 idx:23736 |
| `editProtoMed` | idx:23339 | 1 | idx:23326 |
| `openProtoMedPickModal` | idx:23344 | 1 | idx:23367 |
| `printReceivingSheet` | idx:23397 | 1 | idx:23565 |
| `buildReceivingSheetData` | idx:23403 | 3 | idx:23431 idx:23445 idx:23521 |
| `receivingSheetWeight` | idx:23419 | 6 | idx:4897 idx:4898 idx:23420 idx:23443 idx:23550 idx:23558 |
| `receivingSheetTitle` | idx:23425 | 6 | idx:23432 idx:23456 idx:23470 idx:23523 idx:23554 idx:23560 |
| `receivingSheetText` | idx:23430 | 1 | idx:23561 |
| `receivingSheetPrint` | idx:23442 | 1 | idx:23567 |
| `sharePdfFile` | idx:23492 | 9 | idx:6650 idx:14985 idx:18952 idx:19790 idx:19938 idx:20940 idx:23554 idx:36321 idx:36544 |
| `pdfReady` | idx:23510 | 8 | idx:6615 idx:18902 idx:19769 idx:19886 idx:20938 idx:23551 idx:36282 idx:36481 |
| `buildReceivingSheetPdf` | idx:23518 | 1 | idx:23552 |
| `receivingSheetShare` | idx:23549 | 1 | idx:23568 |
| `receivingSheetEmail` | idx:23557 | 1 | idx:23569 |
| `openProtoMedSubModal` | idx:23571 | 2 | idx:23340 idx:23794 |
| `updateProtoMedOverrideBlock` | idx:23616 | 2 | idx:23611 idx:23666 |
| `editProtoStep` | idx:23739 | 1 | idx:23823 |
| `openProtoStepSubModal` | idx:23743 | 2 | idx:23740 idx:23799 |
| `renderProtoFormSteps` | idx:23802 | 3 | idx:23275 idx:23785 idx:23830 |
| `refreshRanchesCache` | idx:23946 | 7 | idx:23951 idx:24006 idx:24270 idx:24354 idx:24477 idx:24716 idx:24779 |
| `refreshForageTypesCache` | idx:23956 | 5 | idx:23961 idx:24271 idx:24478 idx:24717 idx:24998 |
| `psMd` | idx:23979 | 3 | idx:24149 idx:24150 idx:24165 |
| `psDayBefore` | idx:23983 | 2 | idx:24149 idx:24150 |
| `psSeasonOn` | idx:23988 | 2 | idx:24147 idx:24154 |
| `psDefaultFrom` | idx:23997 | 3 | idx:24096 idx:24145 idx:24239 |
| `loadPastureSetup` | idx:24003 | 5 | idx:10574 idx:24137 idx:24190 idx:24212 idx:24262 |
| `renderPastureSetupGoLive` | idx:24044 | 1 | idx:24038 |
| `renderPastureGrid` | idx:24055 | 1 | idx:24039 |
| `renderPastureSeasons` | idx:24142 | 1 | idx:24040 |
| `renderNonfeedRates` | idx:24216 | 1 | idx:24041 |
| `loadLocations` | idx:24266 | 5 | idx:10565 idx:24343 idx:24710 idx:24831 idx:24993 |
| `showRanchDetail` | idx:24348 | 2 | idx:24339 idx:24497 |
| `openRanchModal` | idx:24501 | 2 | idx:24472 idx:24512 |
| `fetchLocationsForExport` | idx:24518 | 2 | idx:24578 idx:24650 |
| `openPastureModal` | idx:24714 | 3 | idx:24480 idx:24784 idx:24965 |
| `updatePastureCropBlock` | idx:24766 | 2 | idx:24760 idx:24776 |
| `showPastureDetail` | idx:24836 | 6 | idx:18623 idx:18627 idx:24456 idx:24829 idx:24983 idx:25613 |
| `loadForageTypes` | idx:24996 | 2 | idx:24988 idx:25064 |
| `openForageEditModal` | idx:25026 | 2 | idx:25021 idx:25039 |
| `refreshActivePasturesCache` | idx:25073 | 7 | idx:25081 idx:26573 idx:26689 idx:26724 idx:27106 idx:27541 idx:30267 |
| `createPasturePicker` | idx:25099 | 2 | idx:25095 idx:25225 |
| `filterPastures` | idx:25113 | 2 | idx:25128 idx:25310 |
| `renderDropdown` | idx:25127 | 2 | idx:25162 idx:25170 |
| `selectByIndex` | idx:25151 | 2 | idx:25146 idx:25191 |
| `createTwoStepPasturePicker` | idx:25228 | 4 | idx:26822 idx:27258 idx:27661 idx:30401 |
| `uniqueRanches` | idx:25253 | 1 | idx:25262 |
| `filterRanches` | idx:25261 | 1 | idx:25289 |
| `filterPastures` | idx:25268 | 2 | idx:25128 idx:25310 |
| `renderRanchDropdown` | idx:25288 | 2 | idx:25366 idx:25371 |
| `renderPastureDropdown` | idx:25309 | 2 | idx:25392 idx:25396 |
| `selectRanch` | idx:25331 | 2 | idx:25302 idx:25386 |
| `selectPasture` | idx:25352 | 2 | idx:25324 idx:25411 |
| `summarizePastureWeights` | idx:25453 | 3 | idx:6442 idx:7472 idx:25515 |
| `loadLotLocations` | idx:25473 | 2 | idx:8106 idx:25483 |
| `reverseMovementRow` | idx:25716 | 2 | idx:25664 idx:25703 |
| `deleteMovementRow` | idx:25756 | 1 | idx:25706 |
| `openEditAssignmentModal` | idx:25776 | 0 |  |
| `deleteAssignmentRow` | idx:25816 | 0 |  |
| `loadAssumptionHistory` | idx:25870 | 1 | idx:25899 |
| `loadAuditLog` | idx:25898 | 2 | idx:7249 idx:8126 |
| `renderAuditLog` | idx:26118 | 2 | idx:26104 idx:26113 |
| `loadDeathLog` | idx:26264 | 1 | idx:8107 |
| `loadLotHealth` | idx:26331 | 1 | idx:8108 |
| `renderLotHealthCard` | idx:26351 | 1 | idx:26344 |
| `loadHeadAdjustments` | idx:26428 | 1 | idx:8112 |
| `haRpcMessage` | idx:26511 | 2 | idx:26628 idx:26650 |
| `openHeadAdjustModal` | idx:26522 | 2 | idx:26656 idx:26657 |
| `saveHeadAdjustment` | idx:26596 | 1 | idx:26659 |
| `deleteHeadAdjustment` | idx:26638 | 1 | idx:26503 |
| `openDeathsModalForNew` | idx:26678 | 1 | idx:26675 |
| `openDeathsModalForEdit` | idx:26714 | 1 | idx:26309 |
| `renderDeathsRows` | idx:26756 | 6 | idx:26710 idx:26744 idx:26826 idx:26843 idx:26863 idx:26874 |
| `loadTreatmentHistoryForDeath` | idx:26882 | 1 | idx:26748 |
| `openMoveLotModal` | idx:27104 | 1 | idx:27101 |
| `renderMoveLotCurrent` | idx:27177 | 1 | idx:27168 |
| `renderMoveLotDestinations` | idx:27240 | 3 | idx:27170 idx:27278 idx:27295 |
| `updateMoveLotSummary` | idx:27285 | 6 | idx:27224 idx:27235 idx:27262 idx:27272 idx:27279 idx:27282 |
| `computeTagSummary` | idx:27419 | 8 | idx:8022 idx:10304 idx:27477 idx:27717 idx:27777 idx:30541 idx:30635 idx:37959 |
| `parseMissingTags` | idx:27448 | 4 | idx:27715 idx:27769 idx:30539 idx:30633 |
| `loadReceipts` | idx:27453 | 2 | idx:8089 idx:8113 |
| `openReceiptModal` | idx:27528 | 5 | idx:8097 idx:27520 idx:27753 idx:27969 idx:38135 |
| `renderReceiptDestinations` | idx:27629 | 4 | idx:27613 idx:27682 idx:27709 idx:38148 |
| `updateReceiptDestSummary` | idx:27689 | 5 | idx:27633 idx:27665 idx:27676 idx:27686 idx:27737 |
| `updateReceiptTagPreview` | idx:27712 | 3 | idx:27625 idx:27750 idx:38147 |
| `showTagConflictModal` | idx:27900 | 1 | idx:27885 |
| `actuallySaveLoadOut` | idx:27965 | 3 | idx:27890 idx:27939 idx:27956 |
| `loadTags` | idx:28048 | 2 | idx:8119 idx:28137 |
| `loadDoctoring` | idx:28152 | 2 | idx:8120 idx:29870 |
| `renderDoctoringTable` | idx:28201 | 7 | idx:21999 idx:22000 idx:23017 idx:28198 idx:28303 idx:28304 idx:28305 |
| `isPlaceholderEvent` | idx:28259 | 6 | idx:28214 idx:28219 idx:28270 idx:29985 idx:30000 idx:30029 |
| `doctoringRowHtml` | idx:28269 | 1 | idx:28243 |
| `defaultPastureForLot` | idx:28334 | 1 | idx:28760 |
| `docEntryPastureOptions` | idx:28343 | 1 | idx:28800 |
| `initDoctoringEntry` | idx:28362 | 1 | idx:10542 |
| `loadActiveLotTagsForEntry` | idx:28516 | 2 | idx:28510 idx:29050 |
| `onDocEntryActionChange` | idx:28574 | 1 | idx:28374 |
| `updateDocEntryHint` | idx:28591 | 2 | idx:28513 idx:28586 |
| `computeMedCost` | idx:28614 | 3 | idx:11472 idx:28979 idx:29731 |
| `computeDoseSimple` | idx:28630 | 2 | idx:28664 idx:29623 |
| `computeMedsForRow` | idx:28653 | 3 | idx:28383 idx:28752 idx:28841 |
| `projectedWeightForLot` | idx:28677 | 1 | idx:28744 |
| `onDocEntryTagInputKey` | idx:28692 | 1 | idx:28375 |
| `addTagToBatch` | idx:28702 | 1 | idx:28697 |
| `renderDocEntryRows` | idx:28766 | 10 | idx:22255 idx:28386 idx:28512 idx:28585 idx:28763 idx:28829 idx:28847 idx:28866 idx:28877 idx:29018 |
| `clearDoctoringEntryBatch` | idx:28874 | 1 | idx:28376 |
| `saveDoctoringEntryBatch` | idx:28883 | 1 | idx:28377 |
| `initDoctoringSingle` | idx:29031 | 1 | idx:10545 |
| `onDocSingleNTToggle` | idx:29070 | 3 | idx:29035 idx:29044 idx:29285 |
| `onDocSingleTagInput` | idx:29090 | 1 | idx:29034 |
| `onDocSingleTagKey` | idx:29096 | 1 | idx:29033 |
| `resolveSingleTagAndOpen` | idx:29104 | 1 | idx:29101 |
| `onDocSingleNTLotChange` | idx:29133 | 1 | idx:29037 |
| `computeNextNTForLot` | idx:29155 | 5 | idx:11443 idx:29142 idx:29184 idx:29636 idx:29655 |
| `openDocSingleForNT` | idx:29181 | 1 | idx:29036 |
| `openSingleDoctoringModal` | idx:29188 | 2 | idx:29130 idx:29185 |
| `populateDoctoringPastures` | idx:29306 | 2 | idx:29353 idx:29409 |
| `openDoctoringModal` | idx:29359 | 6 | idx:28253 idx:28308 idx:29211 idx:29250 idx:29855 idx:30075 |
| `setDoctoringFormLocked` | idx:29451 | 1 | idx:29443 |
| `initOrUpdateDoctoringDatepicker` | idx:29460 | 2 | idx:29426 idx:29432 |
| `renderMedRows` | idx:29479 | 2 | idx:29422 idx:29431 |
| `toggleDoctoringDrugOffWrap` | idx:29522 | 2 | idx:29436 idx:29628 |
| `autoFillMedsFromAction` | idx:29536 | 2 | idx:29211 idx:29629 |
| `refreshDoctoringContext` | idx:29866 | 2 | idx:29813 idx:29847 |
| `initDoctoringSearch` | idx:29874 | 1 | idx:10548 |
| `populateDoctoringSearchLotList` | idx:29915 | 2 | idx:29894 idx:29904 |
| `debouncedDoctoringSearch` | idx:29934 | 1 | idx:29899 |
| `runDoctoringSearch` | idx:29939 | 7 | idx:29868 idx:29901 idx:29902 idx:29905 idx:29907 idx:29912 idx:29936 |
| `renderDoctoringSearchResults` | idx:29991 | 1 | idx:29988 |
| `doctoringSearchRowHtml` | idx:30028 | 1 | idx:30016 |
| `openDoctoringModalFromSearch` | idx:30066 | 1 | idx:30023 |
| `renderRealizedAdgSection` | idx:30081 | 1 | idx:30244 |
| `loadSales` | idx:30181 | 3 | idx:8111 idx:8114 idx:8115 |
| `openSaleModal` | idx:30259 | 3 | idx:30254 idx:30578 idx:30596 |
| `renderSaleSources` | idx:30360 | 5 | idx:30342 idx:30404 idx:30421 idx:30436 idx:30460 |
| `updateSaleSourceSummary` | idx:30443 | 4 | idx:30364 idx:30415 idx:30440 idx:30566 |
| `updateSaleShrinkPreview` | idx:30469 | 3 | idx:30356 idx:30528 idx:30699 |
| `updateSalePriceFromInput` | idx:30499 | 2 | idx:30522 idx:30531 |
| `updateSaleTagPreview` | idx:30536 | 2 | idx:30355 idx:30565 |
| `setDateValue` | idx:30859 | 19 | idx:9984 idx:10052 idx:13985 idx:20969 idx:20976 idx:20977 idx:20982 idx:26549 idx:26683 idx:26719 idx:27151 idx:27578 idx:27605 idx:30903 idx:37623 …+4 |
| `attachFlatpickrAll` | idx:30880 | 4 | idx:30929 idx:30931 idx:30946 idx:30950 |
| `flatpickrSyncOnValueSet` | idx:30905 | 1 | idx:30891 |
| `makeCollapsibleByIds` | idx:30967 | 1 | idx:31025 |
| `setupActivityCardCollapsibles` | idx:31014 | 2 | idx:8141 idx:8142 |
| `expandCardById` | idx:31040 | 1 | idx:29815 |
| `expandCardOnNextRender` | idx:31045 | 9 | idx:10461 idx:10480 idx:26634 idx:26652 idx:27070 idx:27092 idx:27403 idx:28005 idx:28037 |
| `fdKey` | idx:31096 | 1 | idx:34327 |
| `fdItem` | idx:31097 | 33 | idx:32324 idx:32560 idx:32628 idx:33297 idx:33345 idx:33363 idx:33418 idx:33424 idx:33723 idx:33748 idx:33755 idx:33832 idx:34186 idx:34278 idx:34291 …+18 |
| `fdLoc` | idx:31098 | 7 | idx:32324 idx:32629 idx:34169 idx:34335 idx:34690 idx:35452 idx:36562 |
| `fdCountUnit` | idx:31106 | 6 | idx:34726 idx:34775 idx:34789 idx:34894 idx:34927 idx:36582 |
| `fdRateInUnits` | idx:31120 | 3 | idx:32577 idx:32578 idx:36370 |
| `fdInUnits` | idx:31128 | 5 | idx:32574 idx:34257 idx:34293 idx:34730 idx:36368 |
| `fdLoadRefs` | idx:31139 | 23 | idx:31292 idx:31304 idx:31512 idx:31521 idx:31530 idx:31704 idx:31779 idx:32272 idx:32448 idx:32787 idx:32805 idx:32899 idx:32913 idx:32925 idx:33086 …+8 |
| `fdLoadCountStatus` | idx:31174 | 1 | idx:32444 |
| `fdCountStatusFor` | idx:31181 | 1 | idx:32523 |
| `fdOverdueBays` | idx:31185 | 1 | idx:31192 |
| `fdOverdueDue` | idx:31191 | 1 | idx:32508 |
| `fdLoadOnHand` | idx:31207 | 14 | idx:31531 idx:32807 idx:33581 idx:33616 idx:34082 idx:34477 idx:34565 idx:34578 idx:34961 idx:35188 idx:35276 idx:35328 idx:35524 idx:36665 |
| `fdOnHandFor` | idx:31214 | 6 | idx:33794 idx:34171 idx:34219 idx:34336 idx:35397 idx:35455 |
| `invApplyMaterial` | idx:31225 | 1 | idx:31250 |
| `showInventoryTab` | idx:31245 | 14 | idx:7278 idx:31529 idx:31534 idx:34975 idx:34983 idx:35097 idx:35178 idx:37463 idx:37898 idx:38437 idx:39166 idx:40133 idx:40225 idx:40226 |
| `invLoadVendors` | idx:31361 | 11 | idx:31293 idx:31299 idx:31391 idx:31521 idx:31524 idx:31704 idx:32272 idx:34990 idx:34993 idx:35105 idx:35141 |
| `invVendorOptions` | idx:31371 | 3 | idx:31787 idx:32028 idx:33210 |
| `invEnsureVendor` | idx:31381 | 2 | idx:31907 idx:33499 |
| `invFetchNeeds` | idx:31411 | 1 | idx:31453 |
| `loadInvNeedsCattle` | idx:31422 | 1 | idx:31451 |
| `loadInvNeeds` | idx:31449 | 3 | idx:31282 idx:33588 idx:35100 |
| `invOpenNeedRow` | idx:31509 | 1 | idx:31504 |
| `invUpdateBadge` | idx:31542 | 2 | idx:31465 idx:31555 |
| `invRefreshBadge` | idx:31551 | 8 | idx:6847 idx:31961 idx:32230 idx:33542 idx:33583 idx:33618 idx:35137 idx:35160 |
| `loadInvPurchases` | idx:31576 | 7 | idx:31287 idx:31960 idx:32229 idx:33541 idx:33587 idx:34995 idx:35000 |
| `invPuRender` | idx:31646 | 1 | idx:31643 |
| `invOpenOrder` | idx:31703 | 1 | idx:31609 |
| `invOpenDelivery` | idx:31709 | 1 | idx:31638 |
| `loadInvOrders` | idx:31715 | 4 | idx:31294 idx:31959 idx:35102 idx:35136 |
| `invOpenOrderById` | idx:31772 | 2 | idx:31522 idx:31768 |
| `openInvOrderModal` | idx:31783 | 4 | idx:31707 idx:31780 idx:34990 idx:35106 |
| `invBlankOrderLine` | idx:31812 | 3 | idx:31807 idx:31881 idx:35109 |
| `invRenderOrderLines` | idx:31819 | 5 | idx:31808 idx:31859 idx:31877 idx:31882 idx:35110 |
| `saveInvOrder` | idx:31886 | 1 | idx:35117 |
| `loadInvInvoices` | idx:31970 | 3 | idx:31300 idx:32228 idx:35159 |
| `invOpenInvoiceById` | idx:32012 | 2 | idx:31525 idx:32005 |
| `openInvInvoiceModal` | idx:32023 | 3 | idx:32020 idx:34993 idx:35142 |
| `invLoadInvoiceCandidates` | idx:32071 | 1 | idx:35144 |
| `invRenderInvoiceCandidates` | idx:32084 | 3 | idx:32081 idx:32141 idx:35146 |
| `invRecalcTieOut` | idx:32117 | 6 | idx:32073 idx:32087 idx:32108 idx:32112 idx:32114 idx:35145 |
| `invAllocateByPounds` | idx:32147 | 1 | idx:32202 |
| `saveInvInvoice` | idx:32166 | 1 | idx:35148 |
| `fdLoadOpenOrderLines` | idx:32246 | 1 | idx:32272 |
| `fdOrderLineOptions` | idx:32258 | 1 | idx:33208 |
| `fdPrepReceiptModal` | idx:32271 | 6 | idx:31515 idx:31710 idx:32690 idx:33173 idx:34987 idx:35067 |
| `fdAggregateLayers` | idx:32316 | 2 | idx:32381 idx:32387 |
| `fdRewindOnHand` | idx:32354 | 1 | idx:32453 |
| `fdRollUpToItem` | idx:32394 | 1 | idx:32457 |
| `fdAsOfSelfCheck` | idx:32421 | 2 | idx:32299 idx:32456 |
| `fdAsOfLabel` | idx:32437 | 4 | idx:36431 idx:36451 idx:36491 idx:36544 |
| `loadFeedInventory` | idx:32439 | 5 | idx:31318 idx:35010 idx:35033 idx:35042 idx:35048 |
| `openFdLayers` | idx:32627 | 1 | idx:32615 |
| `loadFdCostCenters` | idx:32699 | 3 | idx:31336 idx:32788 idx:35004 |
| `openFdCostCenterModal` | idx:32744 | 4 | idx:32735 idx:35003 idx:40335 idx:40342 |
| `saveFdCostCenter` | idx:32757 | 1 | idx:35006 |
| `loadFeedLocations` | idx:32800 | 4 | idx:31345 idx:32900 idx:32914 idx:35052 |
| `openFdLocModal` | idx:32842 | 2 | idx:32838 idx:35051 |
| `saveFdLoc` | idx:32864 | 1 | idx:35053 |
| `deleteFdLoc` | idx:32906 | 1 | idx:35055 |
| `loadFeedItems` | idx:32920 | 4 | idx:31342 idx:33087 idx:33101 idx:35058 |
| `fdLocationOptions` | idx:32974 | 6 | idx:31835 idx:33003 idx:33204 idx:33841 idx:34660 idx:35367 |
| `openFdItemModal` | idx:32981 | 2 | idx:32970 idx:35057 |
| `fdSyncVarianceHint` | idx:33013 | 3 | idx:33005 idx:33027 idx:35064 |
| `fdSyncVarianceFromType` | idx:33023 | 1 | idx:35063 |
| `fdSyncUnitDefault` | idx:33032 | 1 | idx:35062 |
| `saveFdItem` | idx:33041 | 1 | idx:35059 |
| `deleteFdItem` | idx:33093 | 1 | idx:35061 |
| `loadFeedReceipts` | idx:33107 | 6 | idx:31321 idx:33540 idx:33582 idx:33617 idx:35070 idx:35071 |
| `fdPaperFlags` | idx:33181 | 1 | idx:33157 |
| `fdItemOptions` | idx:33191 | 7 | idx:31833 idx:33203 idx:34234 idx:35366 idx:35407 idx:35541 idx:35556 |
| `openFdReceiptModal` | idx:33198 | 6 | idx:31516 idx:31712 idx:32691 idx:33174 idx:34987 idx:35068 |
| `fdApplyOrderLine` | idx:33249 | 1 | idx:35072 |
| `fdSyncShrinkBlock` | idx:33296 | 2 | idx:33228 idx:35080 |
| `fdApplyShrink` | idx:33310 | 3 | idx:33307 idx:35081 idx:35082 |
| `fdRcRateBasisLb` | idx:33333 | 2 | idx:33347 idx:33377 |
| `fdSyncCostFromRate` | idx:33342 | 2 | idx:33281 idx:35085 |
| `fdSyncRateFromCost` | idx:33343 | 1 | idx:35086 |
| `fdSyncReceiptCost` | idx:33344 | 2 | idx:33342 idx:33343 |
| `fdUpdateReceiptCost` | idx:33362 | 8 | idx:33242 idx:33268 idx:33325 idx:33359 idx:33421 idx:33429 idx:35088 idx:35089 |
| `fdSyncQtyFromUnits` | idx:33417 | 2 | idx:35080 idx:35083 |
| `fdSyncUnitsFromQty` | idx:33423 | 3 | idx:33264 idx:33318 idx:35084 |
| `saveFdReceipt` | idx:33432 | 1 | idx:35077 |
| `deleteFdReceipt` | idx:33597 | 1 | idx:35079 |
| `fdReopenOrderLineIfEmpty` | idx:33625 | 1 | idx:33613 |
| `fdNewUsageRow` | idx:33646 | 6 | idx:34113 idx:34301 idx:34474 idx:35165 idx:35171 idx:35205 |
| `fdMxMode` | idx:33697 | 3 | idx:34094 idx:34389 idx:35203 |
| `fdShKeyOf` | idx:33704 | 2 | idx:33812 idx:33814 |
| `fdShParse` | idx:33705 | 3 | idx:33710 idx:34009 idx:34046 |
| `fdShLabel` | idx:33709 | 2 | idx:34000 idx:34010 |
| `fdShIsLot` | idx:33718 | 1 | idx:33876 |
| `fdShDefaultLocation` | idx:33722 | 2 | idx:33734 idx:33752 |
| `fdShNewRow` | idx:33730 | 3 | idx:33752 idx:34033 idx:35219 |
| `fdShCommodityRows` | idx:33743 | 2 | idx:33763 idx:35232 |
| `fdShInit` | idx:33761 | 4 | idx:34084 idx:34110 idx:34478 idx:35173 |
| `fdShResetCurrent` | idx:33769 | 2 | idx:34012 idx:35227 |
| `fdShCurrentTotal` | idx:33775 | 1 | idx:33875 |
| `fdShStashedDraw` | idx:33787 | 1 | idx:33799 |
| `fdShBayDraw` | idx:33793 | 2 | idx:33833 idx:33976 |
| `fdShRender` | idx:33804 | 10 | idx:33957 idx:33963 idx:34013 idx:34036 idx:34111 idx:35212 idx:35221 idx:35228 idx:35233 idx:35244 |
| `fdShRenderTie` | idx:33872 | 2 | idx:33905 idx:33983 |
| `fdShRenderDone` | idx:33910 | 1 | idx:33823 |
| `fdShWire` | idx:33946 | 1 | idx:33865 |
| `fdShRefresh` | idx:33970 | 2 | idx:33866 idx:33951 |
| `fdShNext` | idx:33988 | 3 | idx:34022 idx:34389 idx:35223 |
| `fdShReopen` | idx:34020 | 1 | idx:35238 |
| `fdShSyncSheet` | idx:34042 | 3 | idx:33984 idx:34389 idx:35204 |
| `initFeedUsage` | idx:34069 | 1 | idx:31324 |
| `fdApplyUsageMode` | idx:34093 | 5 | idx:34085 idx:34479 idx:35174 idx:35189 idx:35207 |
| `fdCheckOverlap` | idx:34125 | 1 | idx:34414 |
| `fdClaimedElsewhere` | idx:34160 | 2 | idx:34173 idx:34220 |
| `fdLocationLabel` | idx:34168 | 2 | idx:34242 idx:34317 |
| `renderFdUsageRows` | idx:34177 | 5 | idx:34114 idx:34281 idx:34302 idx:34566 idx:35166 |
| `fdRefreshUsageLocationLabels` | idx:34309 | 1 | idx:34294 |
| `fdRenderUsageSummary` | idx:34322 | 2 | idx:34267 idx:34295 |
| `fdValidateUsage` | idx:34357 | 1 | idx:34390 |
| `saveFdUsage` | idx:34387 | 1 | idx:35176 |
| `fdRollbackUsage` | idx:34493 | 1 | idx:34464 |
| `loadFdLedger` | idx:34506 | 4 | idx:34086 idx:34480 idx:34567 idx:35247 |
| `loadFeedCounts` | idx:34575 | 3 | idx:31327 idx:34647 idx:34962 |
| `removeFdCount` | idx:34636 | 1 | idx:34629 |
| `openFdCountModal` | idx:34655 | 2 | idx:31532 idx:35257 |
| `fdRenderCountLines` | idx:34671 | 3 | idx:34668 idx:35258 idx:35259 |
| `postFdCount` | idx:34856 | 1 | idx:35261 |
| `loadFeedBatches` | idx:35273 | 6 | idx:31330 idx:35329 idx:35525 idx:35630 idx:35643 idx:36665 |
| `renderFdRecipeList` | idx:35336 | 1 | idx:35333 |
| `fdNewBatchInput` | idx:35356 | 4 | idx:35363 idx:35390 idx:35445 idx:36671 |
| `openFdBatchModal` | idx:35361 | 1 | idx:36663 |
| `fdApplyRecipe` | idx:35377 | 1 | idx:36674 |
| `renderFdBatchInputs` | idx:35394 | 5 | idx:35371 idx:35391 idx:35433 idx:35446 idx:36672 |
| `fdLocationLabelPlain` | idx:35451 | 1 | idx:35412 |
| `renderFdBatchSummary` | idx:35461 | 2 | idx:35422 idx:35439 |
| `saveFdBatch` | idx:35486 | 1 | idx:36668 |
| `openFdRecipeModal` | idx:35533 | 2 | idx:35352 idx:36676 |
| `renderFdRecipeLines` | idx:35552 | 3 | idx:35548 idx:35578 idx:36683 |
| `saveFdRecipe` | idx:35583 | 1 | idx:36678 |
| `deleteFdRecipe` | idx:35636 | 1 | idx:36679 |
| `loadFeedCost` | idx:35647 | 3 | idx:31333 idx:36692 idx:36693 |
| `fdRwBoxOf` | idx:35761 | 1 | idx:35848 |
| `fdRwTemplateOf` | idx:35765 | 1 | idx:35849 |
| `fdRwLastWeek` | idx:35774 | 4 | idx:35019 idx:35785 idx:39582 idx:40311 |
| `initFdRedwing` | idx:35783 | 1 | idx:31339 |
| `loadFdRedwing` | idx:35792 | 4 | idx:35017 idx:35021 idx:35184 idx:35789 |
| `fdRwBuild` | idx:35840 | 7 | idx:35970 idx:36028 idx:36053 idx:36085 idx:36103 idx:36137 idx:36186 |
| `fdRwSection` | idx:35953 | 4 | idx:36210 idx:36213 idx:36216 idx:36219 |
| `fdRwApplicationHtml` | idx:35969 | 3 | idx:36089 idx:36215 idx:36246 |
| `fdRwPendingFlag` | idx:36016 | 7 | idx:35987 idx:35997 idx:36008 idx:36069 idx:36095 idx:36096 idx:36098 |
| `fdRwTieHtml` | idx:36026 | 1 | idx:36208 |
| `fdRwCentresHtml` | idx:36052 | 2 | idx:36090 idx:36247 |
| `fdRwFeedPostingHtml` | idx:36084 | 2 | idx:36212 idx:36245 |
| `fdRwVarianceHtml` | idx:36102 | 2 | idx:36218 idx:36248 |
| `fdRwRollHtml` | idx:36136 | 2 | idx:36221 idx:36249 |
| `renderFdRedwing` | idx:36184 | 2 | idx:35789 idx:35836 |
| `fdRwCellText` | idx:36238 | 3 | idx:36309 idx:36310 idx:36335 |
| `fdRwSectionHtml` | idx:36244 | 3 | idx:36274 idx:36294 idx:36328 |
| `printFdRwSection` | idx:36252 | 1 | idx:35026 |
| `shareFdRwPdf` | idx:36281 | 1 | idx:35027 |
| `copyFdRwSection` | idx:36326 | 1 | idx:35028 |
| `fdOnHandReport` | idx:36350 | 2 | idx:36407 idx:36483 |
| `printFdOnHand` | idx:36405 | 2 | idx:35012 idx:35015 |
| `shareFdOnHandPdf` | idx:36480 | 1 | idx:35031 |
| `printFdCountSheet` | idx:36561 | 1 | idx:36689 |
| `posPounds` | idx:36737 | 1 | idx:36805 |
| `posHeadlinePrice` | idx:36746 | 1 | idx:36806 |
| `showPositionsTab` | idx:36752 | 1 | idx:15012 |
| `loadPositions` | idx:36764 | 7 | idx:36761 idx:37123 idx:37133 idx:37139 idx:37149 idx:37154 idx:37155 |
| `renderPositionsList` | idx:36796 | 1 | idx:36791 |
| `renderHedgeCoverage` | idx:36846 | 1 | idx:36792 |
| `renderMarketQuotes` | idx:36909 | 1 | idx:36793 |
| `posSyncFields` | idx:36956 | 5 | idx:6173 idx:37045 idx:37156 idx:37157 idx:37158 |
| `posAddLinkRow` | idx:36973 | 2 | idx:37038 idx:37161 |
| `posCollectLinks` | idx:36992 | 1 | idx:37126 |
| `openPositionModal` | idx:37004 | 2 | idx:37153 idx:37169 |
| `savePosition` | idx:37049 | 1 | idx:37162 |
| `posDelete` | idx:37142 | 1 | idx:37160 |
| `invLedgerReady` | idx:37194 | 2 | idx:37211 idx:37281 |
| `invRecordDoctoringUsage` | idx:37209 | 3 | idx:11481 idx:28987 idx:29802 |
| `invRecordProcessingDraw` | idx:37278 | 2 | idx:10452 idx:28015 |
| `invUndoLotMedCharges` | idx:37340 | 2 | idx:8521 idx:22846 |
| `invVoidDoctoring` | idx:37363 | 5 | idx:8525 idx:11616 idx:22853 idx:29000 idx:29839 |
| `invReverseDoctoringForEdit` | idx:37373 | 1 | idx:29778 |
| `invTempId` | idx:37403 | 4 | idx:37715 idx:38352 idx:38538 idx:40148 |
| `invNum` | idx:37409 | 50 | idx:37639 idx:37640 idx:37650 idx:37651 idx:37743 idx:37744 idx:37771 idx:37772 idx:37773 idx:37800 idx:37818 idx:37835 idx:37836 idx:37839 idx:37840 …+35 |
| `invMedById` | idx:37419 | 9 | idx:37741 idx:37844 idx:38347 idx:38553 idx:38570 idx:38617 idx:39390 idx:39431 idx:40171 |
| `loadInvLookups` | idx:37421 | 4 | idx:37468 idx:38235 idx:38322 idx:39938 |
| `invFillLocationSelect` | idx:37439 | 7 | idx:37478 idx:37508 idx:37625 idx:38340 idx:38837 idx:39355 idx:39575 |
| `invFillMedSelect` | idx:37454 | 1 | idx:39354 |
| `showMedInventoryTab` | idx:37466 | 1 | idx:31276 |
| `loadInvOnHand` | idx:37514 | 6 | idx:37479 idx:37509 idx:40126 idx:40137 idx:40138 idx:40139 |
| `loadInvMedPurchases` | idx:37583 | 2 | idx:37485 idx:38450 |
| `openInvPurchaseEntry` | idx:37616 | 2 | idx:38331 idx:40143 |
| `parseInvPasteBlock` | idx:37633 | 1 | idx:37705 |
| `invMatchMedByName` | idx:37658 | 2 | idx:37712 idx:38348 |
| `invNameTokens` | idx:37675 | 2 | idx:37680 idx:37683 |
| `invMedSuggestions` | idx:37679 | 1 | idx:37697 |
| `invMedPickerOptions` | idx:37694 | 1 | idx:37742 |
| `applyInvPaste` | idx:37704 | 1 | idx:40146 |
| `renderInvPurchaseLines` | idx:37730 | 7 | idx:37627 idx:37723 idx:38371 idx:38406 idx:40149 idx:40173 idx:40183 |
| `recomputeInvPurchase` | idx:37769 | 5 | idx:37733 idx:37762 idx:37805 idx:40152 idx:40163 |
| `saveInvPurchase` | idx:37793 | 1 | idx:40151 |
| `loTicketTags` | idx:37923 | 1 | idx:37957 |
| `loResolveTicket` | idx:37931 | 1 | idx:38015 |
| `loadLoadOutIntake` | idx:37998 | 3 | idx:12530 idx:15894 idx:38118 |
| `renderLoadOutIntake` | idx:38025 | 1 | idx:38019 |
| `loPhotoBlobUrl` | idx:38079 | 2 | idx:38093 idx:38154 |
| `loIntakeOnClick` | idx:38088 | 1 | idx:15915 |
| `openLoadOutFromTicket` | idx:38124 | 2 | idx:27531 idx:38098 |
| `loFinishTicket` | idx:38162 | 1 | idx:28019 |
| `medIntakePurchase` | idx:38211 | 2 | idx:38215 idx:38286 |
| `medIntakePosted` | idx:38215 | 4 | idx:11158 idx:38241 idx:38242 idx:38321 |
| `loadMedIntake` | idx:38217 | 3 | idx:12530 idx:15893 idx:38312 |
| `renderMedIntake` | idx:38249 | 1 | idx:38246 |
| `medIntakeOnClick` | idx:38298 | 1 | idx:15914 |
| `openMedIntakeReview` | idx:38318 | 1 | idx:38300 |
| `invPurIntakeLineNote` | idx:38374 | 1 | idx:37748 |
| `invPurNewMed` | idx:38387 | 1 | idx:40179 |
| `invPurLearnAliases` | idx:38414 | 1 | idx:37890 |
| `invPurBackToMeds` | idx:38429 | 2 | idx:37897 idx:38436 |
| `invPurLeave` | idx:38435 | 2 | idx:40144 idx:40145 |
| `deleteInvPurchase` | idx:38440 | 1 | idx:40188 |
| `initInvCheckouts` | idx:38454 | 1 | idx:37488 |
| `invCoDest` | idx:38508 | 2 | idx:38518 idx:38605 |
| `syncInvCoMode` | idx:38517 | 2 | idx:38503 idx:40192 |
| `invCoAddLine` | idx:38536 | 5 | idx:38457 idx:38696 idx:38734 idx:40191 idx:40219 |
| `invCoDefaultSize` | idx:38551 | 1 | idx:40210 |
| `renderInvCoLines` | idx:38558 | 3 | idx:38548 idx:40211 idx:40219 |
| `renderInvCoSummary` | idx:38588 | 3 | idx:38563 idx:38585 idx:40202 |
| `loadInvCrewMembers` | idx:38597 | 2 | idx:38461 idx:39939 |
| `saveInvCheckout` | idx:38604 | 2 | idx:40221 idx:40222 |
| `loadInvCheckoutLog` | idx:38751 | 3 | idx:38504 idx:38698 idx:38736 |
| `loadInvCounts` | idx:38779 | 4 | idx:37494 idx:38827 idx:38831 idx:39188 |
| `deleteInvCount` | idx:38816 | 1 | idx:40238 |
| `openInvCountEntry` | idx:38834 | 2 | idx:40224 idx:40234 |
| `buildInvCountLines` | idx:38867 | 2 | idx:38863 idx:40227 |
| `invCountedUnits` | idx:38938 | 7 | idx:39013 idx:39025 idx:39067 idx:39124 idx:39134 idx:39150 idx:40267 |
| `invCountIsTyped` | idx:38957 | 2 | idx:38965 idx:39015 |
| `invCountBoxesUsed` | idx:38958 | 3 | idx:39013 idx:39017 idx:40280 |
| `invCrewMissing` | idx:38963 | 2 | idx:38975 idx:39075 |
| `carryInvCrewFigures` | idx:38972 | 1 | idx:39093 |
| `renderInvCountLines` | idx:38989 | 3 | idx:38930 idx:38982 idx:40228 |
| `renderInvCountSummary` | idx:39064 | 2 | idx:39061 idx:40265 |
| `saveInvCountDraft` | idx:39096 | 2 | idx:39158 idx:40230 |
| `postInvCount` | idx:39149 | 1 | idx:40231 |
| `unpostInvCount` | idx:39178 | 1 | idx:40236 |
| `printInvCountSheet` | idx:39194 | 2 | idx:40140 idx:40229 |
| `initInvEfficiency` | idx:39258 | 1 | idx:37497 |
| `loadInvEfficiency` | idx:39267 | 2 | idx:39264 idx:40305 |
| `initInvCharge` | idx:39351 | 1 | idx:37491 |
| `invChLoadDestinations` | idx:39361 | 2 | idx:39356 idx:40345 |
| `invChSync` | idx:39385 | 5 | idx:39357 idx:39500 idx:40323 idx:40324 idx:40347 |
| `saveInvCharge` | idx:39427 | 1 | idx:40325 |
| `loadInvChargeList` | idx:39510 | 3 | idx:39358 idx:39501 idx:39568 |
| `undoInvCharge` | idx:39562 | 1 | idx:40328 |
| `initInvReports` | idx:39574 | 1 | idx:37500 |
| `loadInvReport` | idx:39594 | 4 | idx:39591 idx:40315 idx:40317 idx:40318 |
| `renderInvApplication` | idx:39729 | 1 | idx:39622 |
| `copyInvReportRows` | idx:39912 | 1 | idx:40319 |
| `printInvReport` | idx:39920 | 1 | idx:40320 |
| `loadInvSetup` | idx:39937 | 6 | idx:37503 idx:39967 idx:39976 idx:40038 idx:40076 idx:40091 |
| `renderInvCrew` | idx:39945 | 1 | idx:39941 |
| `addInvCrewMember` | idx:39961 | 1 | idx:40295 |
| `deactivateInvCrewMember` | idx:39970 | 1 | idx:40298 |
| `renderInvGoLive` | idx:39979 | 1 | idx:39940 |
| `setInvGoLive` | idx:40019 | 2 | idx:40009 idx:40013 |
| `renderInvLocations` | idx:40041 | 1 | idx:39942 |
| `addInvLocation` | idx:40059 | 1 | idx:40300 |
| `purgeInvLocation` | idx:40079 | 1 | idx:40303 |
| `settleInvUncovered` | idx:40104 | 2 | idx:37875 idx:40141 |
| `invChAfterCcSave` | idx:40344 | 2 | idx:40334 idx:40341 |
| `helpAllowed` | idx:40946 | 3 | idx:40951 idx:40952 idx:40983 |
| `helpRoleChanged` | idx:40950 | 2 | idx:6840 idx:6853 |
| `helpSetOpen` | idx:40958 | 2 | idx:41072 idx:41073 |
| `helpScreenKeys` | idx:40966 | 1 | idx:40984 |
| `helpCardsFor` | idx:40976 | 1 | idx:40986 |
| `helpFmt` | idx:40979 | 5 | idx:41013 idx:41015 idx:41016 idx:41017 idx:41021 |
| `helpSync` | idx:40982 | 3 | idx:40956 idx:40962 idx:41102 |
| `helpRender` | idx:41008 | 4 | idx:41006 idx:41058 idx:41082 idx:41100 |
| `helpClearGlow` | idx:41024 | 5 | idx:40952 idx:40962 idx:41056 idx:41080 idx:41098 |
| `helpVisible` | idx:41028 | 3 | idx:41038 idx:41042 idx:41051 |
| `helpNorm` | idx:41031 | 6 | idx:41036 idx:41037 idx:41039 idx:41042 idx:41050 idx:41051 |
| `helpFindTarget` | idx:41035 | 1 | idx:41061 |
| `helpPickStep` | idx:41053 | 2 | idx:41086 idx:41090 |

## All functions: field app

| Name | Defined | Refs | Where |
|---|---|---|---|
| `loadJSON` | app:80 | 18 | app:94 app:95 app:96 app:97 app:98 app:99 app:106 app:110 app:116 app:122 app:128 app:132 app:275 app:276 app:277 …+3 |
| `setSelectValue` | app:140 | 3 | app:241 app:2636 app:2687 |
| `tagToInt` | app:154 | 3 | app:150 app:161 app:2901 |
| `tagKey` | app:160 | 4 | app:166 app:2544 app:2664 app:2759 |
| `resolveLotForTag` | app:165 | 2 | app:2632 app:2902 |
| `historyPool` | app:182 | 4 | app:2629 app:2716 app:2834 app:2887 |
| `pendingMovesInto` | app:193 | 2 | app:214 app:228 |
| `lotStandsIn` | app:208 | 3 | app:2662 app:2734 app:3072 |
| `lotPlaces` | app:218 | 3 | app:2666 app:2735 app:3073 |
| `setLocationLabel` | app:234 | 1 | app:250 |
| `showToast` | app:305 | 33 | app:247 app:363 app:373 app:378 app:602 app:730 app:736 app:749 app:762 app:818 app:1169 app:1174 app:1504 app:1508 app:1527 …+18 |
| `pruneOldRecords` | app:336 | 1 | app:368 |
| `safeSetItem` | app:354 | 26 | app:387 app:391 app:580 app:581 app:974 app:1920 app:1921 app:2035 app:2039 app:2113 app:2114 app:2115 app:2116 app:2117 app:2118 …+11 |
| `saveQueue` | app:386 | 3 | app:407 app:744 app:811 |
| `saveTombstones` | app:390 | 2 | app:2031 app:2141 |
| `enqueueForSync` | app:394 | 1 | app:2981 |
| `isPermanentError` | app:423 | 1 | app:557 |
| `plainError` | app:430 | 2 | app:596 app:602 |
| `toIsoOrNull` | app:454 | 2 | app:505 app:518 |
| `daysOnFeedFrom` | app:468 | 1 | app:2785 |
| `toStagingRow` | app:483 | 1 | app:552 |
| `sendOne` | app:527 | 3 | app:562 app:565 app:793 |
| `saveFailed` | app:578 | 4 | app:600 app:626 app:742 app:774 |
| `moveToFailed` | app:584 | 2 | app:558 app:802 |
| `visibleFailed` | app:632 | 3 | app:636 app:674 app:675 |
| `openFailedCount` | app:635 | 1 | app:642 |
| `updateFailedBadge` | app:639 | 4 | app:601 app:745 app:775 app:831 |
| `localStamp` | app:648 | 1 | app:686 |
| `describeFailed` | app:653 | 1 | app:680 |
| `renderFailedList` | app:670 | 5 | app:715 app:747 app:748 app:776 fidx:704ʰ |
| `processSyncQueue` | app:779 | 6 | app:410 app:748 app:849 app:851 app:852 app:3962 |
| `updateSyncBadge` | app:822 | 10 | app:408 app:746 app:781 app:782 app:785 app:813 app:849 app:850 app:3953 app:3960 |
| `clearTooltip` | app:864 | 4 | app:875 app:942 app:945 app:957 |
| `showTooltipFor` | app:871 | 1 | app:929 |
| `findTooltipTarget` | app:909 | 1 | app:922 |
| `cancelPress` | app:933 | 3 | app:937 app:939 app:945 |
| `saveLocks` | app:973 | 1 | app:1005 |
| `renderLockButton` | app:977 | 5 | app:992 app:1008 app:1009 app:1010 app:1011 |
| `wireLockButton` | app:989 | 4 | app:1019 app:1020 app:1021 app:1022 |
| `restoreLockedValues` | app:1025 | 1 | app:3150 |
| `snapshotLockedValues` | app:1060 | 1 | app:3140 |
| `updateChuteBanner` | app:1070 | 3 | app:1013 app:3156 app:3955 |
| `openKeypad` | app:1095 | 3 | app:1136 app:1137 app:3166 |
| `closeKeypad` | app:1101 | 4 | app:1107 app:1147 app:1155 fidx:594ʰ |
| `renderKeypadDisplay` | app:1109 | 2 | app:1097 app:1127 |
| `updateDailySummary` | app:1181 | 6 | app:1925 app:2045 app:2148 app:3159 app:3954 app:3961 |
| `switchTab` | app:1234 | 6 | app:1269 app:1270 app:1271 app:1272 app:1953 app:3308 |
| `checkDailySync` | app:1283 | 1 | app:3963 |
| `pvStocked` | app:1331 | 2 | app:1354 app:1369 |
| `openPastureView` | app:1349 | 1 | app:1258 |
| `pvPastureOptions` | app:1368 | 1 | app:1426 |
| `renderPastureView` | app:1374 | 4 | app:1365 app:1428 app:1430 fidx:465 |
| `pvWhere` | app:1446 | 5 | app:1460 app:1478 app:1500 app:1580 app:1610 |
| `pvShowForm` | app:1452 | 8 | app:1364 app:1384 app:1469 app:1528 app:1538 app:1648 app:1653 app:1654 |
| `pvOpenCount` | app:1465 | 1 | app:1651 |
| `pvCompareCount` | app:1476 | 2 | app:1470 app:1657 |
| `pvSaveCount` | app:1499 | 1 | app:1655 |
| `pvOpenWeigh` | app:1532 | 1 | app:1652 |
| `pvAddDraftRow` | app:1541 | 2 | app:1537 app:1658 |
| `pvDraftValues` | app:1566 | 2 | app:1588 app:1611 |
| `pvWeighNeed` | app:1579 | 2 | app:1591 app:1627 |
| `pvWeighTotals` | app:1586 | 6 | app:1554 app:1561 app:1563 app:1587 app:1659 fidx:518 |
| `pvSaveWeigh` | app:1609 | 1 | app:1656 |
| `populateMoveDropdowns` | app:1661 | 1 | app:1252 |
| `updateMovePastures` | app:1676 | 4 | app:1696 app:1700 app:1959 app:1965 |
| `moveLotsHere` | app:1733 | 1 | app:1759 |
| `proRata` | app:1743 | 1 | app:1802 |
| `renderMoveSplit` | app:1755 | 4 | app:1698 app:1703 app:1839 app:1930 |
| `autoFillMoveSplit` | app:1795 | 2 | app:1707 app:1789 |
| `moveSplitValues` | app:1807 | 2 | app:1818 app:1862 |
| `updateMoveSplitTotal` | app:1815 | 6 | app:1708 app:1782 app:1790 app:1800 app:1801 app:1804 |
| `refreshMoveLots` | app:1837 | 1 | app:1977 |
| `fetchAllPages` | app:2178 | 7 | app:2196 app:2232 app:2258 app:2273 app:2279 app:2297 app:2314 |
| `fetchOpenLotTags` | app:2195 | 1 | app:2462 |
| `pullCloudData` | app:2209 | 5 | app:109 app:1299 app:2584 app:2589 app:3412 |
| `triggerMedAutoFill` | app:2591 | 3 | app:2356 app:2606 app:2941 |
| `updateAlertBox` | app:2701 | 7 | app:252 app:2698 app:2970 app:2975 app:2977 app:3077 app:3192 |
| `openAppModal` | app:2817 | 2 | app:2873 app:3673 |
| `closeAppModal` | app:2825 | 2 | app:2877 app:3678 |
| `validateActionSafety` | app:2883 | 2 | app:2924 app:3060 |
| `updateDataLists` | app:2945 | 3 | app:2143 app:3952 app:3959 |
| `pushToCloud` | app:2979 | 5 | app:1526 app:1646 app:1923 app:2043 app:3137 |
| `clearMissingFields` | app:2989 | 3 | app:2996 app:3057 app:3143 |
| `flagMissingFields` | app:2995 | 1 | app:3054 |
| `getHistoryCutoff` | app:3215 | 2 | app:3224 app:3237 |
| `updateRecentList` | app:3222 | 4 | app:1263 app:2040 app:2145 app:3693 |
| `updateMovesList` | app:3235 | 3 | app:1264 app:2036 app:2146 |
| `renderDoctoringRow` | app:3248 | 2 | app:3231 app:3702 |
| `statusCell` | app:3266 | 2 | app:3252 app:3286 |
| `rowActions` | app:3272 | 2 | app:3258 app:3294 |
| `renderMoveRow` | app:3283 | 1 | app:3244 |
| `escapeHtml` | app:3376 | 13 | app:681 app:683 app:684 app:685 app:686 app:3625 app:3641 app:3644 app:3648 app:3649 app:3650 app:3653 app:3654 |
| `localDay` | app:3386 | 12 | app:2218 app:3446 app:3526 app:3561 app:3574 app:3578 app:3579 app:3659 app:3661 app:3662 app:3665 app:3671 |
| `dayReportLabel` | app:3391 | 1 | app:3562 |
| `drCompareTags` | app:3403 | 1 | app:3627 |
| `buildDayReport` | app:3413 | 1 | app:2551 |
| `renderDayReport` | app:3558 | 2 | app:3667 app:3672 |
| `dayReportCard` | app:3637 | 1 | app:3628 |
| `shiftDayReport` | app:3658 | 2 | app:3675 app:3676 |
| `setCurrentDateTime` | app:3680 | 2 | app:3144 app:3951 |
| `updateFormVisibility` | app:3681 | 4 | app:2928 app:2932 app:3153 app:3321 |
| `displayRecords` | app:3691 | 1 | app:3704 |
| `refreshResetState` | app:3742 | 3 | app:829 app:3768 app:3817 |
| `resetAppData` | app:3760 | 1 | app:3810 |
| `showLoginError` | app:3846 | 5 | app:3872 app:3882 app:3892 app:3931 app:3936 |
| `onSignedIn` | app:3851 | 2 | app:3934 app:3969 |
| `showLoginScreen` | app:3912 | 3 | app:3947 app:3970 app:3976 |
| `startApp` | app:3958 | 1 | app:3909 |
| `report` | fidx:153 | 19 | app:2213 app:2227 app:2231 app:2291 app:2294 app:2302 app:2318 app:2331 app:2332 app:2549 app:3360 app:3364 app:3374 app:3412 fidx:76 …+4 |
| `hardReset` | fidx:176 | 1 | fidx:216 |
