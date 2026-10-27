import sharp from 'sharp';
// Workers must not each create a CPU-sized native thread pool or retain a
// second unaccounted image cache beside the editor's document/history buffers.
sharp.cache(false);
sharp.concurrency(1);
export default sharp;
