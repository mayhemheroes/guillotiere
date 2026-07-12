// Upstream's fuzz/fuzz_targets/alloc_dealloc.rs, ported to libfuzzer-sys 0.4 /
// arbitrary 1 (upstream's fuzz/ crate pins libfuzzer-sys 0.3 + arbitrary 0.4,
// which don't build on the pinned nightly). Harness logic is unchanged.
#![no_main]

use libfuzzer_sys::arbitrary::Arbitrary;
use libfuzzer_sys::fuzz_target;

use guillotiere::*;

#[derive(Copy, Clone, Arbitrary, Debug)]
enum Evt {
    Alloc(i32, i32),
    Dealloc(usize),
}

fuzz_target!(|events: Vec<Evt>| {
    let mut atlas = AtlasAllocator::new(size2(1000, 1000));
    let mut allocations = Vec::new();

    for evt in &events {
        match *evt {
            Evt::Alloc(w, h) => {
                if let Some(alloc) = atlas.allocate(size2(w, h)) {
                    allocations.push(alloc.id);
                }
            }
            Evt::Dealloc(idx) => {
                if idx < allocations.len() {
                    atlas.deallocate(allocations[idx]);
                    allocations.swap_remove(idx);
                }
            }
        }

        let mut count = 0;
        atlas.for_each_allocated_rectangle(&mut |_id: AllocId, _r: &Rectangle| {
            count += 1;
        });

        assert_eq!(count, allocations.len());
    }

    for id in allocations {
        atlas.deallocate(id);
    }
});
