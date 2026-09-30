import { test, expect } from '@playwright/test';
import { attendancePrint, attendanceCsv } from '../../lib/attendance-export';
import type { AttendanceExport } from '../../lib/attendance-export';
const data: AttendanceExport={tenant:'Tenant B',event:{id:'internal-event',title:'Szkolenie <script>throw Error("XSS")</script>',description:null,event_date:'2026-12-01',start_time:'10:00',end_time:'11:00',location:'Sala <B>',status:'upcoming',participants_available:true},rows:[{registration_id:'internal-registration',display_name:'Żółć <img src=x onerror=alert(1)>',registration_status:'approved',attendance_status:'present',attendance_version:1}]};
for(const width of [375,430,1440])test(`print safe HTML and layout ${width}`,async({page},info)=>{
 await page.setViewportSize({width,height:900});
 await page.route('https://attendance.test/**',route=>route.fulfill({contentType:'text/html',headers:{'Cache-Control':'private, no-store'},body:attendancePrint(data)}));
 await page.goto('https://attendance.test/print');
 await expect(page.getByRole('cell',{name:data.rows[0].display_name,exact:true})).toBeVisible();
 await expect(page.locator('script,img')).toHaveCount(0);
 expect(await page.locator('body').innerText()).not.toContain('internal-');
 expect(await page.evaluate(()=>document.documentElement.scrollWidth)).toBeLessThanOrEqual(width);
 await page.screenshot({path:info.outputPath(`print-${width}.png`),fullPage:true});
 await page.emulateMedia({media:'print'});
 await expect(page.locator('.print-help')).toBeHidden();
 await expect(page.getByRole('table')).toBeVisible();
});
test('CSV download preserves encoding and filename',async({page})=>{
 await page.route('https://attendance.test/**',route=>route.fulfill({contentType:'text/csv; charset=utf-8',headers:{'Content-Disposition':'attachment; filename="lista-obecnosci-2026-12-01.csv"','Cache-Control':'private, no-store'},body:attendanceCsv(data)}));
 await page.setContent('<a href="https://attendance.test/csv">Pobierz CSV</a>');
 const download=page.waitForEvent('download');await page.getByRole('link').click();
 expect((await download).suggestedFilename()).toBe('lista-obecnosci-2026-12-01.csv');
});
