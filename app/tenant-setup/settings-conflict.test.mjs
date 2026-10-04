import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import ts from 'typescript';
const code=ts.transpileModule(readFileSync(new URL('./settings-validation.ts',import.meta.url),'utf8'),{compilerOptions:{module:ts.ModuleKind.ESNext,target:ts.ScriptTarget.ES2022}}).outputText;
const {mapSettingsError,parseHours}=await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));
test('PT409 settings_conflict remains a safe form conflict with no field error',()=>{
 const mapped=mapSettingsError({code:'PT409',message:'settings_conflict'},{display_name:'Synthetic',city:'Testowo'},parseHours(null));
 assert.equal(mapped.conflict,true);assert.deepEqual(mapped.fields,{});assert.equal(mapped.summary,'Ustawienia zostały zmienione w innym miejscu. Odśwież dane i spróbuj ponownie.');assert.doesNotMatch(mapped.summary,/PT409|settings_conflict/);
});
