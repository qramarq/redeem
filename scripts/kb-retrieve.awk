# kb-retrieve.awk — rank markdown sections for a diagnostic dump.
# Usage: awk -f kb-retrieve.awk -v queryfile=diag.txt -v maxbytes=1600 file.md ...
# Splits on ATX headings and scores chunks with BM25. No embeddings.

BEGIN {
    k1 = 1.2
    b = 0.75
    if (maxbytes <= 0) {
        maxbytes = 1600
    }
    if (queryfile == "") {
        print "kb-retrieve: queryfile is required" > "/dev/stderr"
        exit 2
    }
    while ((getline line < queryfile) > 0) {
        qtext = qtext " " line
    }
    close(queryfile)
    nq = tokenize(qtext, qtf)
}

FNR == 1 {
    flush_chunk()
    current = ""
    title = FILENAME
    infile = FILENAME
}

/^#+ / {
    flush_chunk()
    title = $0
    sub(/^#+ /, "", title)
    current = ""
    next
}

{
    current = current $0 "\n"
}

END {
    flush_chunk()
    if (nchunks == 0) {
        exit 0
    }
    avgdl = total_tokens / nchunks
    if (avgdl < 1) {
        avgdl = 1
    }
    for (i = 1; i <= nchunks; i++) {
        score[i] = 0
        for (term in qtf) {
            tf = tfcount[i, term]
            if (tf == 0) {
                continue
            }
            n = df[term]
            idf = log(1 + (nchunks - n + 0.5) / (n + 0.5))
            denom = tf + k1 * (1 - b + b * dlen[i] / avgdl)
            score[i] += idf * (tf * (k1 + 1)) / denom
        }
    }
    used = 0
    emitted = 0
    for (pick = 1; pick <= nchunks; pick++) {
        best = 0
        best_i = 0
        for (i = 1; i <= nchunks; i++) {
            if (taken[i]) {
                continue
            }
            if (score[i] > best) {
                best = score[i]
                best_i = i
            }
        }
        if (best_i == 0 || best <= 0) {
            break
        }
        taken[best_i] = 1
        block = "[" infile_of[best_i] " # " title_of[best_i] "]\n" body[best_i]
        blen = length(block)
        if (emitted > 0 && used + blen > maxbytes) {
            break
        }
        if (blen > maxbytes && emitted == 0) {
            block = substr(block, 1, maxbytes)
            blen = length(block)
        }
        printf "%s", block
        if (substr(block, length(block), 1) != "\n") {
            printf "\n"
        }
        printf "\n"
        used += blen + 1
        emitted++
        if (emitted >= 4) {
            break
        }
    }
    if (emitted == 0) {
        print "[no knowledge-pack section matched these diagnostics]"
    }
}

function flush_chunk(   n, i, w, seen) {
    if (current == "" || length(current) < 40) {
        current = ""
        return
    }
    nchunks++
    body[nchunks] = current
    title_of[nchunks] = title
    sub(/.*\//, "", infile)
    infile_of[nchunks] = infile
    n = tokenize(current, tmp)
    dlen[nchunks] = n
    total_tokens += n
    for (w in tmp) {
        tfcount[nchunks, w] = tmp[w]
        if (!(seen[w])) {
            df[w]++
            seen[w] = 1
        }
    }
    delete tmp
    current = ""
}

function tokenize(text, out,   n, i, w, parts, count) {
    count = 0
    n = split(tolower(text), parts, /[^a-z0-9]+/)
    for (i = 1; i <= n; i++) {
        w = parts[i]
        if (length(w) < 3 || isstop(w)) {
            continue
        }
        out[w]++
        count++
    }
    return count
}

function isstop(w) {
    return w == "the" || w == "and" || w == "for" || w == "that" || w == "this" || \
        w == "with" || w == "from" || w == "are" || w == "was" || w == "were" || \
        w == "not" || w == "you" || w == "your" || w == "our" || w == "but" || \
        w == "have" || w == "has" || w == "had" || w == "its" || w == "into" || \
        w == "about" || w == "than" || w == "then" || w == "them" || w == "they" || \
        w == "will" || w == "can" || w == "only" || w == "when" || w == "what" || \
        w == "which" || w == "also" || w == "any" || w == "all" || w == "per" || \
        w == "device" || w == "disk" || w == "partition" || w == "file" || w == "size"
}
