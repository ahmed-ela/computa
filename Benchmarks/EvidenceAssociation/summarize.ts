const paths = Bun.argv.slice(2);
if (!paths.length) throw new Error("Supply summary.json files");
for (const path of paths) {
  const data = await Bun.file(path).json();
  const median = (xs:number[]) => { const a=[...xs].sort((a,b)=>a-b); return a.length ? a.length%2 ? a[(a.length-1)/2] : (a[a.length/2-1]+a[a.length/2])/2 : null; };
  console.log(JSON.stringify({path,state:data.state,attemptedRequests:data.attemptedRequests,split:data.split,
    arms:[...new Set<string>(data.rows.map((r:any)=>r.arm))].map(arm=>{
      const rows = data.rows.filter((r:any)=>r.arm===arm), answered=rows.filter((r:any)=>r.state==="answered");
      return {arm,lanes:rows.length,answered:answered.length,exact:answered.filter((r:any)=>r.score.exact).length,
        validJSON:answered.filter((r:any)=>r.score.valid).length,
        unsupported:answered.reduce((n:number,r:any)=>n+r.score.unsupported,0),
        omitted:answered.reduce((n:number,r:any)=>n+r.score.omitted,0),extra:answered.reduce((n:number,r:any)=>n+r.score.extra,0),
        noCompletion:rows.filter((r:any)=>r.state!=="answered").map((r:any)=>({id:r.id,state:r.state})),
        medianMsAllFinishedLanes:median(rows.filter((r:any)=>typeof r.elapsed_ms==="number").map((r:any)=>r.elapsed_ms)),
        medianMsAnsweredLanes:median(answered.map((r:any)=>r.elapsed_ms))};
    })},null,2));
}
