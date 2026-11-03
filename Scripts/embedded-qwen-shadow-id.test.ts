import { expect, test } from 'bun:test';
import { fixture, choice, fingerprint, prompt, answerID } from './embedded-qwen-adapter-fixture';
for (const label of ['Qwen3.7-Plus','Qwen3.8-Max']) test(label+' exposes only a settled previously bound owned reply ID on opted-in final inspection',async()=>{
  for(const variant of ['match','ordinary','cleanup','binding','wrong-hash','wrong-choice','alternate','extra-phase','still-streaming']){
    const f=fixture({completeOnSend:variant!=='still-streaming'}), wanted=choice(variant==='alternate'?'Qwen3.8-Omni-Flash':label);
    for(let i=0;i<8;i++)if((await f.run('selectModel',{modelChoice:wanted})).selected)break;
    expect((await f.run('prepare')).prepared).toBe(true);
    expect((await f.run('insert',{prompt})).inserted).toBe(true);
    const hash=await fingerprint(prompt);
    expect((await f.run('submit',{prompt,savedSubmissionFingerprint:hash})).submitted).toBe(true);
    expect((await f.run('inspect')).firstUserVerified).toBe(true);
    if(variant==='extra-phase')f.flow.append(f.phase.cloneNode(true));
    const r=await f.run('inspect',{qwenSyntheticMarkerComparison:variant!=='ordinary',
      allowFirstUserBinding:variant==='binding',savedCleanupInspection:variant==='cleanup',
      expectedModelChoice:variant==='wrong-choice'?choice('another'):wanted,
      expectedFirstUserFingerprint:variant==='wrong-hash'?'0'.repeat(64):hash});
    if(variant==='match'){expect(r.answerComplete).toBe(true);expect(r.qwenShadowResponseID).toBe(answerID);}
    else expect(r.qwenShadowResponseID).toBeUndefined();
    expect(f.send.clicks).toBe(1);
  }
});
