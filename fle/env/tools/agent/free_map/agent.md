# free_map

`free_map(x0, y0, x1, y1, cell=4)` reads what occupies every cell of a rectangle in one call: '.' free, 'o' free on ore, 't' trees/rocks only, '#' our entities, 'w' water, 'E' enemy buildings. Returns {"x0", "y0", "cell", "rows", "counts"}. play_lib.show_free() prints it with axes; find_free(w, h, near) picks the nearest clear box from it.
