#' Filter and trim a fastq file.
#' 
#' fastqFilter takes an input fastq file (can be compressed), filters it based on several
#' user-definable criteria, and outputs those reads which pass the filter and their associated
#' qualities to a new fastq file (also can be compressed). Several functions in the \code{ShortRead}
#' package are leveraged to do this filtering.
#' 
#' \code{fastqFilter} replicates most of the functionality of the fastq_filter command in usearch
#' (http://www.drive5.com/usearch/manual/cmd_fastq_filter.html). It adds the ability to remove
#' contaminating phiX sequences as part of the filtering process.
#' 
#' @param fn (Required). The path to the input fastq file.
#'   
#' @param fout (Required). The path to the output file.
#'  Note that by default (\code{compress=TRUE}) the output fastq file is gzipped.
#' 
#' @param truncQ (Optional). Default 2.
#'  Truncate reads at the first instance of a quality score less than or equal to \code{truncQ}.
#'  The default value of 2 is a special quality score indicating the end of good quality
#'    sequence in Illumina 1.8+.
#'  
#' @param truncLen (Optional). Default 0 (no truncation).
#'  Truncate reads after \code{truncLen} bases. Reads shorter than this are discarded.
#'  Note that \code{\link{dada}} currently requires all sequences to be the same length.
#'  
#' @param trimLeft (Optional). Default 0.
#'  The number of nucleotides to remove from the start of each read. If both \code{truncLen} and 
#'  \code{trimLeft} are provided, filtered reads will have length \code{truncLen-trimLeft}.
#'  
#' @param maxN (Optional). Default 0.
#'  After truncation, sequences with more than \code{maxN} Ns will be discarded. 
#'  Note that \code{\link{dada}} currently does not allow Ns.
#'  
#' @param minQ (Optional). Default 0.
#'  After truncation, reads contain a quality score below minQ will be discarded.
#'
#' @param maxEE (Optional). Default \code{Inf} (no EE filtering).
#'  After truncation, reads with higher than maxEE "expected errors" will be discarded.
#'  Expected errors are calculated from the nominal definition of the quality score: EE = sum(10^(-Q/10))
#'  
#' @param rm.phix (Optional). Default FALSE.
#'  If TRUE, discard reads that match against the phiX genome, as determined by 
#'  \code{\link{isPhiX}}.
#'
#' @param n (Optional). The number of records (reads) to read in and filter at any one time. 
#'  This controls the peak memory requirement so that very large fastq files are supported. 
#'  Default is \code{1e6}, one-million reads. See \code{\link{FastqStreamer}} for details.
#'
#' @param compress (Optional). Default TRUE.
#'  Whether the output fastq file should be gzip compressed.
#' 
#' @param verbose (Optional). Default FALSE.
#'  Whether to output status messages.  
#' 
#' @param ... (Optional). Arguments passed on to \code{\link{isPhiX}}.
#' 
#' @return \code{integer(2)}.
#'  The number of reads read in, and the number of reads that passed the filter and were output.
#' 
#' @seealso 
#'  \code{\link{fastqPairedFilter}}
#' 
#'  \code{\link[ShortRead]{FastqStreamer}}
#'  
#'  \code{\link[ShortRead]{srFilter}}
#'  
#'  \code{\link[ShortRead]{trimTails}}
#' 
#' @export
#' 
#' @importFrom ShortRead FastqStreamer
#' @importFrom ShortRead yield
#' @importFrom ShortRead writeFastq
#' @importFrom ShortRead trimTails
#' @importFrom ShortRead nFilter
#' @importFrom ShortRead encoding
#' @importFrom Biostrings quality
#' @importFrom Biostrings narrow
#' @importFrom Biostrings width
#' @importFrom Biostrings end
#' @importFrom methods as
#' 
#' @examples
#' testFastq = system.file("extdata", "sam1F.fastq.gz", package="dada2")
#' filtFastq <- tempfile(fileext=".fastq.gz")
#' fastqFilter(testFastq, filtFastq, maxN=0, maxEE=2)
#' fastqFilter(testFastq, filtFastq, trimLeft=10, truncLen=200, maxEE=2, verbose=TRUE)
#' 
fastqFilter <- function(fn, fout, truncQ = 2, truncLen = 0, trimLeft = 0, maxN = 0, minQ = 0, maxEE = Inf, rm.phix=FALSE, n = 1e6, compress = TRUE, verbose = FALSE, ...){
  start <- max(1, trimLeft + 1, na.rm=TRUE)
  end <- truncLen
  if(end < start) { end = NA }
  end <- end - start + 1
  
  if(fn == fout) { stop("The output and input files must be different.") }
  
  ## iterating over an entire file using fastq streaming
  f <- FastqStreamer(fn, n = n)
  on.exit(close(f))
  
  # Delete fout if it already exists (since writeFastq doesn't overwrite)
  if(file.exists(fout)) {
    if(file.remove(fout)) {
      if(verbose) message("Overwriting file:", fout)
    } else {
      stop("Failed to overwrite file:", fout)
    }
  }
  
  first=TRUE
  inseqs = 0
  outseqs = 0
  while( length(suppressWarnings(fq <- yield(f))) ){
    inseqs <- inseqs + length(fq)
    
    # Trim left
    fq <- fq[width(fq) >= start]
    fq <- narrow(fq, start = start, end = NA)
    # Trim on truncQ 
    # Convert numeric quality score to the corresponding ascii character
    if(is.numeric(truncQ)) {
      enc <- encoding(quality(fq))
      ind <- which(enc==truncQ)
      if(length(ind) != 1) stop("Encoding for this truncQ value not found.")
      truncQ <- names(enc)[[ind]]
    }
    if(length(fq) > 0) fq <- trimTails(fq, 1, truncQ)
    # Filter any with less than required length
    if(!is.na(end)) { fq <- fq[width(fq) >= end] }
    # Truncate to truncLen
    fq <- narrow(fq, start = 1, end = end)
    
    # Filter based on minQ and Ns and maxEE
    keep <- rep(TRUE, length(fq))
    suppressWarnings(keep <- keep & minQFilter(minQ)(fq))
    keep <- keep & nFilter(maxN)(fq)
    if(maxEE < Inf) keep <- keep & maxEEFilter(maxEE)(fq)
    fq <- fq[keep]
    
    # Remove phiX
    if(rm.phix) {
      is.phi <- isPhiX(as(sread(fq), "character"), ...)
      fq <- fq[!is.phi]
    }
    
    outseqs <- outseqs + length(fq)
    
    if(first) {
      writeFastq(fq, fout, "w", compress=compress)
      first=FALSE
    } else {
      writeFastq(fq, fout, "a", compress=compress)
    }
  }
  
  if(verbose) {
    message("Read in ", inseqs, ", output ", outseqs, " filtered sequences.")
  }
  
  if(outseqs==0) {
    message(paste("The filter removed all reads:", fout, "not written."))
    file.remove(fout)
  }
  
  return(invisible(c(reads.in=inseqs, reads.out=outseqs)))
}
#' Filters and trims paired forward and reverse fastq files.
#' 
#' fastqPairedFilter takes in two input fastq file (can be compressed), filters them based on several
#' user-definable criteria, and outputs those reads which pass the filter in both directions along
#' with their associated qualities to two new fastq file (also can be compressed). Several functions
#' in the \code{ShortRead} package are leveraged to do this filtering. The filtered forward/reverse reads
#' remain identically ordered.
#' 
#' fastqPairedFilter replicates most of the functionality of the fastq_filter command in usearch
#' (http://www.drive5.com/usearch/manual/cmd_fastq_filter.html) but only pairs of reads that both
#' pass the filter are retained. An added function is the option to remove
#' contaminating phiX sequences as part of the filtering process.
#' 
#' @param fn (Required). A \code{character(2)} naming the paths to the (forward,reverse) fastq files.
#'   
#' @param fout (Required). A \code{character(2)} naming the paths to the (forward,reverse) output files.
#'  Note that by default (\code{compress=TRUE}) the output fastq files are gzipped.
#' 
#' \strong{FILTERING AND TRIMMING ARGUMENTS} that follow can be provided as length 1 or length 2 vectors. 
#' If a length 1 vector is provided, the same parameter value is used for the forward and reverse sequence files.
#' If a length 2 vector is provided, the first value is used for the forward reads, and the second 
#'   for the reverse reads.
#' 
#' @param truncQ (Optional). Default 2.
#'  Truncate reads at the first instance of a quality score less than or equal to \code{truncQ}.
#'  The default value of 2 is a special quality score indicating the end of good quality
#'    sequence in Illumina 1.8+.
#'  
#' @param truncLen (Optional). Default 0 (no truncation).
#'  Truncate reads after \code{truncLen} bases. Reads shorter than this are discarded.
#'  Note that \code{\link{dada}} currently requires all sequences to be the same length.
#'  
#' @param trimLeft (Optional). Default 0.
#'  The number of nucleotides to remove from the start of each read. If both \code{truncLen} and 
#'  \code{trimLeft} are provided, filtered reads will have length \code{truncLen-trimLeft}.
#'  
#' @param maxN (Optional). Default 0.
#'  After truncation, sequences with more than \code{maxN} Ns will be discarded. 
#'  Note that \code{\link{dada}} currently does not allow Ns.
#'  
#' @param minQ (Optional). Default 0.
#'  After truncation, reads contain a quality score below minQ will be discarded.
#'
#' @param maxEE (Optional). Default \code{Inf} (no EE filtering).
#'  After truncation, reads with higher than maxEE "expected errors" will be discarded.
#'  Expected errors are calculated from the nominal definition of the quality score: EE = sum(10^(-Q/10))
#'  
#' @param rm.phix (Optional). Default FALSE.
#'  If TRUE, discard reads that match against the phiX genome, as determined by 
#'  \code{\link{isPhiX}}.
#'
#' \strong{ID MATCHING ARGUMENTS} that follow enforce matching between the sequence identification
#'  strings in the forward and reverse reads. The function can automatically detect and match ID fields in 
#'  Illumina format, e.g: EAS139:136:FC706VJ:2:2104:15343:197393
#' 
#' @param matchIDs (Optional). Default FALSE.
#'  Whether to enforce matching between the id-line sequence identifiers of the forward and reverse fastq files.
#'    If TRUE, only paired reads that share id fields (see below) are output.
#'    If FALSE, no read ID checking is done.
#'  Note: \code{matchIDs=FALSE} essentially assumes matching order between forward and reverse reads. If that
#'    matched order is not present future processing steps may break (in particular \code{\link{mergePairs}}).
#'
#' @param id.sep (Optional). Default "\\s" (white-space).
#'  The separator between fields in the id-line of the input fastq files. Passed to the \code{\link{strsplit}}.
#' 
#' @param id.field (Optional). Default NULL (automatic detection).
#'  The field of the id-line containing the sequence identifier.
#'  If NULL (the default) and matchIDs is TRUE, the function attempts to automatically detect
#'    the sequence identifier field under the assumption of Illumina formatted output.
#'
#' @param n (Optional). The number of records (reads) to read in and filter at any one time. 
#'  This controls the peak memory requirement so that very large fastq files are supported. 
#'  Default is \code{1e6}, one-million reads. See \code{\link{FastqStreamer}} for details.
#'  
#' @param compress (Optional). Default TRUE.
#'  Whether the output fastq files should be gzip compressed.
#' 
#' @param verbose (Optional). Default FALSE.
#'  Whether to output status messages.  
#' 
#' @param ... (Optional). Arguments passed on to \code{\link{isPhiX}}.
#' 
#' @return \code{integer(2)}.
#'  The number of reads read in, and the number of reads that passed the filter and were output.
#' 
#' @seealso 
#' \code{\link{fastqFilter}}
#' 
#' \code{\link[ShortRead]{FastqStreamer}}
#' 
#' \code{\link[ShortRead]{srFilter}}
#' 
#' \code{\link[ShortRead]{trimTails}}
#' 
#' @export
#' 
#' @importFrom ShortRead FastqStreamer
#' @importFrom ShortRead yield
#' @importFrom ShortRead writeFastq
#' @importFrom ShortRead trimTails
#' @importFrom ShortRead nFilter
#' @importFrom ShortRead encoding
#' @importFrom ShortRead append
#' @importFrom ShortRead ShortReadQ
#' @importFrom Biostrings quality
#' @importFrom Biostrings narrow
#' @importFrom Biostrings width
#' @importFrom Biostrings end
#' @importFrom methods as
#' 
#' @examples
#'
#' testFastqF = system.file("extdata", "sam1F.fastq.gz", package="dada2")
#' testFastqR = system.file("extdata", "sam1R.fastq.gz", package="dada2")
#' filtFastqF <- tempfile(fileext=".fastq.gz")
#' filtFastqR <- tempfile(fileext=".fastq.gz")
#' fastqPairedFilter(c(testFastqF, testFastqR), c(filtFastqF, filtFastqR), maxN=0, maxEE=2)
#' fastqPairedFilter(c(testFastqF, testFastqR), c(filtFastqF, filtFastqR), trimLeft=c(10, 20),
#'                     truncLen=c(240, 200), maxEE=2, rm.phix=TRUE, verbose=TRUE)
#' 
fastqPairedFilter <- function(fn, fout, maxN = c(0,0), truncQ = c(2,2), truncLen = c(0,0), trimLeft = c(0,0), minQ = c(0,0), maxEE = c(Inf, Inf), rm.phix = c(FALSE, FALSE), matchIDs = FALSE, id.sep = "\\s", id.field = NULL, n = 1e6, compress = TRUE, verbose = FALSE, ...){
  # Warning: This assumes that forward/reverse reads are in the same order unless matchIDs=TRUE
  if(!is.character(fn) || length(fn) != 2) stop("Two paired input file names required.")
  if(!is.character(fout) || length(fout) != 2) stop("Two paired output file names required.")
  
  if(any(duplicated(c(fn, fout)))) { stop("The output and input file names must be different.") }
  
  for(var in c("maxN", "truncQ", "truncLen", "trimLeft", "minQ", "maxEE", "rm.phix")) {
    if(length(get(var)) == 1) { # Double the 1 value to be the same for F and R
      assign(var, c(get(var), get(var)))
    }
    if(length(get(var)) != 2) {
      stop(paste("Input variable", var, "must be length 1 or 2 (Forward, Reverse)."))
    }
  }
  
  startF <- max(1, trimLeft[[1]] + 1, na.rm=TRUE)
  startR <- max(1, trimLeft[[2]] + 1, na.rm=TRUE)
  
  endF <- truncLen[[1]]
  if(endF < startF) { endF = NA }
  endF <- endF - startF + 1
  endR <- truncLen[[2]]
  if(endR < startR) { endR = NA }
  endR <- endR - startR + 1
  
  ## iterating over forward and reverse files using fastq streaming
  fF <- FastqStreamer(fn[[1]], n = n)
  on.exit(close(fF))
  fR <- FastqStreamer(fn[[2]], n = n)
  on.exit(close(fR), add=TRUE)
  
  if(file.exists(fout[[1]])) {
    if(file.remove(fout[[1]])) {
      if(verbose) message("Overwriting file:", fout[[1]])
    } else {
      stop("Failed to overwrite file:", fout[[1]])
    }
  }
  if(file.exists(fout[[2]])) {
    if(file.remove(fout[[2]])) {
      if(verbose) message("Overwriting file:", fout[[2]])
    } else {
      stop("Failed to overwrite file:", fout[[2]])
    }
  }
  
  first=TRUE
  remainderF <- ShortReadQ(); remainderR <- ShortReadQ()
  casava <- "Undetermined"
  inseqs = 0; outseqs = 0
  while( TRUE ) {
    suppressWarnings(fqF <- yield(fF))
    suppressWarnings(fqR <- yield(fR))
    if(length(fqF) == 0 && length(fqR) == 0) { break } # Loop Logic
    
    inseqs <- inseqs + length(fqF)
    
    if(matchIDs) {
      if(first) { 
        if(is.null(id.field)) {
          # Determine the sequence identifier field. Looks for a single 6-colon field (CASAVA 1.8+ id format)
          # or a single 4-colon field (earlier format). Fails if it doesn't find such a field.
          id1 <- as.character(id(fqF)[[1]])
          id.fields <- strsplit(id1, id.sep)[[1]]
          ncolon <- sapply(gregexpr(":", id.fields), length)
          ncoltab <- table(ncolon)
          if(max(ncolon) == 6 && ncoltab["6"] == 1) { # CASAVA 1.8+ format
            casava <- "Current"
            id.field <- which(ncolon == 6)
          } else if (max(ncolon) == 4 && ncoltab["4"] == 1) { # CASAVA <=1.7 format
            casava <- "Old"
            id.field <- which(ncolon == 4)
          } else { # Couldn't unambiguously find the seq id field
            stop("Couldn't automatically detect the sequence identifier field in the fastq id string.")
          }
        }
      } else { # !first
        # Prepend the unmatched sequences from the end of previous chunks
        # Need ShortRead::append or the method is not dispatched properly
        fqF <- append(remainderF, fqF)
        fqR <- append(remainderR, fqR)
      }
    } else { # !matchIDs
      if(length(fqF) != length(fqR)) stop("Mismatched forward and reverse sequence files: ", length(fqF), ", ", length(fqR), ".")
    }
    
    # Enforce id matching (ASSUMES SAME ORDERING IN F/R, BUT ALLOWS DIFFERENTIAL MEMBERSHIP)
    # Keep the tail of unmatched sequences (could match next chunk)
    if(matchIDs) {
      idsF <- sapply(strsplit(as.character(id(fqF)), id.sep), `[`, id.field)
      idsR <- sapply(strsplit(as.character(id(fqR)), id.sep), `[`, id.field)
      if(casava == "Old") { # Drop the index number/pair identifier (i.e. 1=F, 2=R)
        idsF <- sapply(strsplit(idsF, "#"), `[`, 1)
      }
      lastF <- max(which(idsF %in% idsR))
      lastR <- max(which(idsR %in% idsF))
      if(lastF < length(fqF)) {
        remainderF <- fqF[(lastF+1):length(fqF)]
      } else {
        remainderF <- ShortReadQ() 
      }
      if(lastR < length(fqR)) {
        remainderR <- fqR[(lastR+1):length(fqR)]
      } else {
        remainderR <- ShortReadQ() 
      }
      fqF <- fqF[idsF %in% idsR]
      fqR <- fqR[idsR %in% idsF]
    }
    
    # Trim left
    keep <- (width(fqF) >= startF & width(fqR) >= startR)
    fqF <- fqF[keep]
    fqF <- narrow(fqF, start = startF, end = NA)
    fqR <- fqR[keep]
    fqR <- narrow(fqR, start = startR, end = NA)
    # Trim on truncQ
    # Convert numeric quality score to the corresponding ascii character
    if(is.numeric(truncQ)) {
      encF <- encoding(quality(fqF))
      encR <- encoding(quality(fqR))
      indF <- which(encF==truncQ[[1]])
      indR <- which(encR==truncQ[[2]])
      if(!(length(indF) == 1 && length(indR) == 1)) stop("Encoding for this truncQ value not found.")
      truncQ <- c(names(encF)[[indF]], names(encR)[[indR]])
    }
    if(length(fqF) > 0) {
      rngF <- trimTails(fqF, 1, truncQ[[1]], ranges=TRUE)
      fqF <- narrow(fqF, 1, end(rngF)) # have to do it this way to avoid dropping the zero lengths
    }
    if(length(fqR) > 0) {
      rngR <- trimTails(fqR, 1, truncQ[[2]], ranges=TRUE)
      fqR <- narrow(fqR, 1, end(rngR)) # have to do it this way to avoid dropping the zero lengths
    }
    # And now filter any with length zero in F or R
    # May want to roll this into the next length cull step...
    keep <- (width(fqF) > 0 & width(fqR) > 0)
    fqF <- fqF[keep]
    fqR <- fqR[keep]
    
    # Filter any with less than required length
    keep <- rep(TRUE, length(fqF))
    if(!is.na(endF)) { keep <- keep & (width(fqF) >= endF) }
    if(!is.na(endR)) { keep <- keep & (width(fqR) >= endR) }
    fqF <- fqF[keep]
    fqR <- fqR[keep]
    # Truncate to truncLen
    fqF <- narrow(fqF, start = 1, end = endF)
    fqR <- narrow(fqR, start = 1, end = endR)
    
    # Filter based on minQ and Ns and maxEE
    keep <- rep(TRUE, length(fqF))
    suppressWarnings(keep <- keep & minQFilter(minQ[[1]])(fqF) & nFilter(maxN[[1]])(fqF))
    if(maxEE[[1]] < Inf) keep <- keep & maxEEFilter(maxEE[[1]])(fqF)
    suppressWarnings(keep <- keep & minQFilter(minQ[[2]])(fqR) & nFilter(maxN[[2]])(fqR))
    if(maxEE[[2]] < Inf) keep <- keep & maxEEFilter(maxEE[[2]])(fqR)
    fqF <- fqF[keep]
    fqR <- fqR[keep]
    
    if(length(fqF) != length(fqR)) stop("Filtering caused mismatch between forward and reverse sequence lists: ", length(fqF), ", ", length(fqR), ".")
    
    # Remove phiX
    if(rm.phix[[1]] && rm.phix[[2]]) {
      is.phi <- isPhiX(as(sread(fqF), "character"), ...)
      is.phi <- is.phi | isPhiX(as(sread(fqR), "character"), ...)
    } else if(rm.phix[[1]] && !rm.phix[[2]]) {
      is.phi <- isPhiX(as(sread(fqF), "character"), ...)
    } else if(!rm.phix[[1]] && rm.phix[[2]]) {
      is.phi <- isPhiX(as(sread(fqR), "character"), ...)
    }
    if(any(rm.phix)) {
      fqF <- fqF[!is.phi]
      fqR <- fqR[!is.phi]
    }
    
    outseqs <- outseqs + length(fqF)    
    
    if(first) {
      writeFastq(fqF, fout[[1]], "w", compress = compress)
      writeFastq(fqR, fout[[2]], "w", compress = compress)
      first=FALSE
    } else {
      writeFastq(fqF, fout[[1]], "a", compress = compress)
      writeFastq(fqR, fout[[2]], "a", compress = compress)
    }
  }
  
  if(outseqs==0) {
  }
  
  if(verbose) {
    message("Read in ", inseqs, " paired-sequences, output ", outseqs, " filtered paired-sequences.")
  }
  
  if(outseqs==0) {
    message(paste("The filter removed all reads:", fout[[1]], "and", fout[[2]], "not written."))
    file.remove(fout[[1]])
    file.remove(fout[[2]])
  }
  
  return(invisible(c(reads.in=inseqs, reads.out=outseqs)))
}

#' @importFrom ShortRead srFilter
#' @importFrom ShortRead SRFilterResult
#' @importFrom Biostrings quality
#' @importFrom methods as
minQFilter <- function (minQ = 0L, .name = "MinQFilter") 
{
  srFilter(function(x) {
    apply(as(quality(x), "matrix"), 1, function(qs) min(qs, na.rm=TRUE) >= minQ)
  }, name = .name)
}

#' @importFrom Biostrings quality
#' @importFrom ShortRead SRFilterResult
#' @importFrom ShortRead srFilter
#' @importFrom methods as
maxEEFilter <- function (maxEE = Inf, .name = "MaxEEFilter") 
{
  srFilter(function(x) {
    apply(as(quality(x), "matrix"), 1, function(qs) sum(10^(-qs[!is.na(qs)]/10.0)) <= maxEE)
  }, name = .name)
}

#' @importFrom Biostrings width
#' @importFrom ShortRead SRFilterResult
#' @importFrom ShortRead srFilter
minLenFilter <- function(minLen = 0L, .name = "MinLenFilter"){
  srFilter(function(x) {
    width(x) >= minLen
  }, name = .name)
}

################################################################################
#' Determine if input sequence(s) match the phiX genome.
#' 
#' This function compares the word-profile of the input
#' sequences to the phiX genome, and the reverse complement of the phiX genome. If
#' enough exactly matching words are found, the sequence is flagged.
#' 
#' @param seqs (Required). A \code{character} vector of A/C/G/T sequences.
#' 
#' @param wordSize (Optional). Default 16.
#'  The size of the words to use for comparison.
#'   
#' @param minMatches (Optional). Default 2.
#' The minimum number of words in the input sequences that must match the phiX genome
#' (or its reverse complement) for the sequence to be flagged.
#' 
#' @param nonOverlapping (Optional). Default TRUE.
#' If TRUE, only non-overlapping matching words are counted.
#' 
#' @return \code{logical(1)}.
#'  TRUE if sequence matched the phiX genome.
#'
#' @seealso 
#'  \code{\link{fastqFilter}}, \code{\link{fastqPairedFilter}}
#'  
#' @export
#' 
#' @importFrom ShortRead readFasta
#' @importFrom methods as
#' 
#' @examples
#' derep1 = derepFastq(system.file("extdata", "sam1F.fastq.gz", package="dada2"))
#' sqs1 <- getSequences(derep1)
#' isPhiX(sqs1)
#' isPhiX(sqs1, wordSize=20,  minMatches=1)
#' 
isPhiX <- function(seqs, wordSize=16, minMatches=2, nonOverlapping=TRUE) {
  seqs <- getSequences(seqs)
  sq.phix <- as(sread(readFasta(system.file("extdata", "phix_genome.fa", package="dada2"))), "character")
  rc.phix <- rc(sq.phix)
  hits <- C_matchRef(seqs, sq.phix, wordSize, nonOverlapping)
  hits.rc <- C_matchRef(seqs, rc.phix, wordSize, nonOverlapping)
  return((hits >= minMatches) | (hits.rc >= minMatches))
}
