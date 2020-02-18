#!/bin/bash
INPUT=$1
OUTPUT=$2
PARALLEL_JOB_LIMIT=${3:-8}

if [ -z "$OUTPUT" ]; then
	echo "Usage: $0 <input scad file> <output file> [MAX_PARALLEL_JOBS]"
	echo "The output file must not yet exist, and must have as extension '.amf'."
	echo "MAX_PARALLEL_JOBS defaults to 8, reduce if you're low on RAM."
	exit 1
fi

if [ -e "$OUTPUT" ]; then
	echo "Output '$OUTPUT' already exists, aborting."
	exit 1
fi
FORMAT=${OUTPUT##*.}
if [ "$FORMAT" != amf ]; then
	echo "Error: the output file's extension must be 'amf', but it is '$FORMAT'."
	exit 1
fi
INTERMEDIATE=$FORMAT # Format of the per-color intermediate results.

if ! which openscad &> /dev/null; then
	echo "Error: openscad command not found! Make sure it's in your PATH."
	exit 1
fi

# Convert input to a .csg file, mainly to resolve named colors. Also to evaluate functions etc. only once.
# Put .csg file in current directory, to be cygwin-friendly (Windows openscad doesn't know about /tmp/).
INPUT_CSG=$(mktemp --tmpdir=. --suffix=.csg)
openscad "$INPUT" -o "$INPUT_CSG"

# Working directory, plus cleanup trigger
TEMPDIR=$(mktemp -d)
trap "rm -Rf '$INPUT_CSG' '$TEMPDIR'" EXIT

echo "Get list of used colors"
# Here we run openscad once on the .csg file, with a redefined "color" module that just echoes its parameters. There are two outputs:
# 1) The echoed color values, which are extracted, sorted and stored in COLORS.
# 2) Any geometry not wrapped in a color(), which is stored in TEMPDIR as "no_color.stl".
# Colors are sorted on decreasing number of occurrences. The sorting is to gamble that more color mentions,
# means more geometry; we want to start the biggest jobs first to improve parallelism.
COLOR_ID_TAG="colorid_$$_${RANDOM}"
TEMPFILE=$(mktemp --tmpdir=. --suffix=.stl)
COLORS=$(
	openscad "$INPUT_CSG" -o "$TEMPFILE" -D "module color(c) {echo(${COLOR_ID_TAG}=str(c));}" 2>&1 |
	sed -n "s/\\r//g; s/\"//g; s/^ECHO: ${COLOR_ID_TAG} = // p" |
	sort |
	uniq -c |
	sort -rn |
	sed 's/^[^\[]*//'
)
mv "$TEMPFILE" "${TEMPDIR}/no_color.stl"
COLOR_COUNT=$(echo "$COLORS" | wc -l)

# If "no_color.stl" contains anything, it's considered a fatal error:
# any geometry that doesn't have a color assigned, would end up in all per-color AMF files
if [ -s "${TEMPDIR}/no_color.stl" ]; then
	echo
	echo "Fatal error: some geometry is not wrapped in a color() module."
	echo "For a stacktrace, try running:"
	echo -n "openscad '$INPUT' -o output.csg -D 'module color(c,alpha=1){}"
	for primitive in cube sphere cylinder polyhedron; do
		echo -n " module ${primitive}(){assert(false);}"
	done
	echo "'"
	exit 1
fi

echo
echo "Create a separate .${INTERMEDIATE} file for each color"
IFS=$'\n'
JOBS=0
JOB_ID=0
for COLOR in $COLORS; do
	let JOB_ID++
	if [ $JOBS -ge $PARALLEL_JOB_LIMIT ]; then
		# Wait for one job to finish, before continuing
		wait -n
		let JOBS--
	fi
	# Run job in background, and prefix all terminal output with the job ID and color to show progress
	(
		echo Starting
		# To support Windows/cygwin, render to temp file in input directory and later move it to TEMPDIR.
		TEMPFILE=$(mktemp --tmpdir=. --suffix=.${INTERMEDIATE})
		openscad "$INPUT_CSG" -o "$TEMPFILE" -D "module color(c) {if (str(c) == \"${COLOR}\") children();}"
		mv "$TEMPFILE" "${TEMPDIR}/${COLOR}.${INTERMEDIATE}"
		echo Done
	) 2>&1 | sed "s/^/${JOB_ID}\/${COLOR_COUNT} ${COLOR} /" &
	let JOBS++
done
# Wait for all remaining jobs to finish
wait

echo
echo "Generate a merged .${FORMAT} file"
if [ "$FORMAT" = amf ]; then
	{
		echo '<?xml version="1.0" encoding="UTF-8"?>'
		echo '<amf unit="millimeter">'
		echo ' <metadata type="producer">ColorSCAD</metadata>'
		id=0
		IFS=$'\n'
		for COLOR in $COLORS; do
			IFS=','; set -- $COLOR
			R=${1#[}
			G=$2
			B=$3
			A=${4%]}
			echo " <material id=\"${id}\"><color><r>${R// }</r><g>${G// }</g><b>${B// }</b><a>${A// }</a></color></material>"
			let id++
		done
		id=0
		IFS=$'\n'
		for COLOR in $COLORS; do
			if grep -q -m 1 object "${TEMPDIR}/${COLOR}.amf"; then
				echo " <object id=\"${id}\">"
				# Crudely skip the AMF header/footer; assume there is exactly one "<object>" tag and keep only its contents
				cat "${TEMPDIR}/${COLOR}.amf" | tail -n +5 | head -n -1 | sed "s/<volume>/<volume materialid=\"${id}\">/"
			else
				echo "Skipping ${COLOR}!" >&2
			fi
			let id++
			echo -ne "\r${id}/${COLOR_COUNT} " >&2
		done
		echo '</amf>'
	} > "$OUTPUT"

	echo
	echo "AMF file created successfully."
	echo "To create a compressed AMF, run:"
	echo "  zip '${OUTPUT}.zip' '$OUTPUT' && mv '${OUTPUT}.zip' '${OUTPUT}'"
	echo "But, be aware that some tools may not support compressed AMF files."
else
	echo "Merging of format '${FORMAT}' not yet implemented!"
fi

echo "Done"
