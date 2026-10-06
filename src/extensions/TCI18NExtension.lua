-- Base-game code that looks up a mod-registered MoneyType's display text
-- does so two different ways: HUD.lua's money-change toast passes
-- moneyType.customEnv through explicitly (fine, as long as MoneyType.register
-- was given one — which none of ours are), but FinanceStats.new() calls
-- g_i18n:getText("finance_" .. statName) with NO modEnv at all, so it only
-- ever checks I18N's global (unscoped) text table — never a mod's own
-- l10n file. Every custom stat we register (Company.lua's tcCompanyCreation,
-- Advertising.lua's tcAdvertising, ...) would silently render as a missing-
-- text placeholder in the in-game Finances screen without this.
--
-- Same fix FS25_RedTape uses (src/extensions/I18NExtension.lua): patch
-- I18N:getText so that when no modEnv was given AND the requested key is
-- one of ours, resolve it against our own mod environment instead of the
-- global table. Every text name a MoneyType.register call references here
-- (both its title key and the matching "finance_<statName>" key the base
-- game derives from it) needs an entry below.

TCI18NExtension = {}
local modName = g_currentModName

TCI18NExtension.theContractorTexts = {
    ["tc_moneyType_companyCreation"] = true,
    ["finance_tcCompanyCreation"] = true,
    ["tc_moneyType_advertising"] = true,
    ["finance_tcAdvertising"] = true,
    ["tc_moneyType_hiring"] = true,
    ["finance_tcHiring"] = true,
    ["tc_moneyType_wages"] = true,
    ["finance_tcWages"] = true,
    ["tc_moneyType_jobPayout"] = true,
    ["finance_tcJobPayout"] = true,
    ["tc_moneyType_overheads"] = true,
    ["finance_tcOverheads"] = true,
    ["tc_moneyType_claims"] = true,
    ["finance_tcClaims"] = true,
    ["tc_moneyType_legal"] = true,
    ["finance_tcLegal"] = true,
    ["tc_moneyType_training"] = true,
    ["finance_tcTraining"] = true,
    ["tc_moneyType_fines"] = true,
    ["finance_tcFines"] = true,
}

function TCI18NExtension:getText(superFunc, text, modEnv)
    if modEnv == nil and TCI18NExtension.theContractorTexts[text] then
        return superFunc(self, text, modName)
    end

    return superFunc(self, text, modEnv)
end

I18N.getText = Utils.overwrittenFunction(I18N.getText, TCI18NExtension.getText)
