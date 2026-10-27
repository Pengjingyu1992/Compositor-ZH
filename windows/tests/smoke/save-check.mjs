import {expect}from'@playwright/test';

export async function waitForSaved(page){
  // Durable staged saves can outlast the short default DOM assertion timeout
  // on shared Windows disks. A real application error still fails immediately.
  await expect.poll(async()=>{
    const errors=await page.locator('[role=alert]').allTextContents();
    if(errors.length)throw new Error('Save reported: '+errors.join(' · '));
    return {saved:/\bSaved\b|已保存/.test(await page.locator('.badge').innerText()),busy:await page.getByTestId('save-project').isDisabled()};
  },{timeout:30000,message:'Wait for the staged save and recovery cleanup to complete'}).toEqual({saved:true,busy:false});
}
