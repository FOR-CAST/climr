#' Create gcm input for `downscale`.
#' @param gcm A character vector. Label of the global circulation models to use.
#' Can be obtained from `list_gcm()`. Default to `list_gcm()`.
#' @param ssp A character vector. Label of the shared socioeconomic pathways to use.
#' Can be obtained from `list_ssp()`. Default to `list_ssp()`.
#' @param period A character vector. Label of the period to use.
#' Can be obtained from `list_period()`. Default to `list_period()`.
#' @param max_run An integer. Maximum number of model runs to include.
#' A value of 0 is `ensembleMean` only. Runs are included in the order they are found in the
#' models data untile `max_run` is reached. Default to 0L.
#' @return An object to use with `downscale`. A `SpatRaster` with, possibly, multiple layers.
#' @details Will use raster package for now. Switch to terra methods once it gets
#' better performance. See
#' https://gis.stackexchange.com/questions/413105/terrarast-vs-rasterbrick-for-loading-in-nc-files.
#' @importFrom raster brick stack
#' @importFrom utils head
#' @export
gcm_input <- function(gcm = list_gcm(), ssp = list_ssp(), period = list_period() , max_run = 0L) {
  
  # Check if we have data, if not download some.
  data_check()
  
  # Get relevant files
  get_rel_files <- function(pattern, gcm) {
    res <- lapply(
      file.path(
        data_path(),
        getOption("climRpnw.gcm.path", default = "inputs_pkg/gcm"),
        gcm
      ),
      list.files, recursive = TRUE, full.names = TRUE, pattern = pattern
    )
    names(res) <- gcm
    res
  }
  files_nc <- get_rel_files("\\.nc$", gcm)
  files_csv <- get_rel_files("\\.csv$", gcm)
  
  # Check if we have non matching gcmIndex for gcmData
  index_check(findex = files_csv, fdata = files_nc)
  
  # Load each file individually + select layers
  process_one_gcm <- function(data, index, ssp, period) {
    
    # Initiate list
    bricks <- list()
    
    # Select runs + ensembleMean (since alphabetical sort, ensembleMean will be first element)
    runs <- utils::head(list_unique(index, 5L), max_run + 1L)
    
    # process one file
    for (i in seq_len(length(index))) {
      # Read in csv file with headers
      values <- data.table::fread(index[i], header = TRUE)
      # Always select reference
      reference_lines <- which(grepl("_reference_", values[["x"]], fixed = TRUE))
      # Select other layers
      pattern <- paste0(
        "(",
        paste0(ssp, collapse = "|"),
        ")_(",
        paste0(runs, collapse = "|"),
        ")_(",
        paste0(period, collapse = "|"),
        ")$"
      )
      match_lines <- which(grepl(pattern, values[["x"]]))
      # Extract layer numbers
      lyrs <- as.integer(values[["V1"]])[c(reference_lines, match_lines)]
      # Extract layer names
      lyrs_names <- values[["x"]][c(reference_lines, match_lines)]
      # Read data as brick
      brick <- raster::brick(data[i])[[lyrs]]
      # Rename layers
      names(brick) <- lyrs_names
      # Compute deltas (differences with reference layers)
      brick <- delta_to_reference(brick)
      # Include in brick list
      bricks <- append(bricks, brick)
    }
    
    # Directly using terra::rast does not preserve NA value from disk to memory.
    # It stores -max.int32. Workaround until fixed. Use raster::brick, do math
    # operation then use terra::rast.
    
    # Combine into one brick and turn into SpatRaster
    one_gcm <- terra::rast(raster::brick(raster::stack(bricks)))
    
    return(one_gcm)
  }
  
  # Substract reference layers, only keep deltas, plus load in memory instead of disk
  delta_to_reference <- function(layers) {
    
    # Store names for later use
    nm <- names(layers)
    
    # Find matching reference layer for each layer
    # reference will match with itself
    matching_ref <- vapply(
      strsplit(nm, "_"),
      function(x) {
        grep(
          paste(
            paste0(x[1:3], collapse = "_"),
            "reference_",
            sep = "_"
          ),
          nm
        )
      },
      integer(1)
    )
    
    # Reference layers positions
    # They will be used to avoid computing deltas of
    # reference layers with themselves
    uniq_ref <- sort(unique(matching_ref))
    
    # Substract reference layer, this takes a few seconds as all
    # data have to be loaded in memory from disk
    layers <- layers[[-uniq_ref]] - layers[[matching_ref[-uniq_ref]]]
    
    # Return layers without the references
    return(layers)
  }
  
  res <- mapply(process_one_gcm, files_nc, files_csv, MoreArgs = list(ssp = ssp, period = period))
  attr(res, "builder") <- "climRpnw" 
  
  # Return a list of SpatRaster, one element for each model
  return(res)
  
}

#' Read and parse gcm models csv files
#' @param files A character vector. File paths.
#' @param col_num An integer vector. Positions of elements to retrieve in label. Label is split
#' by "_" before processing.
#' @return A character vector of unique values.
list_unique <- function(files, col_num) {
  collection <- character()
  for (file in files) {
    # Read in csv file with headers
    values <- data.table::fread(file, header = TRUE)
    # Remove reference lines
    values <- values[which(!grepl("_reference_", values[["x"]], fixed = TRUE)),]
    # Split and extract sub part of x according to col_num
    values <- vapply(strsplit(values[["x"]], "_"), `[`, character(length(col_num)), col_num)
    # In case we have more than one col_num, put them back together
    if (length(col_num) > 1L) {
      values <- apply(values, 2, paste0, collapse = "_")
    }
    # Reassign collection to unique values
    collection <- unique(c(values, collection))
  }
  # Sort and return
  return(sort(collection))
}

#' Read and parse gcm models csv files
#' @param gcm An optional character vector. Limit list to provided global circulation models.
#' @param col_num An integer vector. 
#' @return A character vector of unique values.
list_parse <- function(gcm, col_num = 1) {
  
  #Default pattern csv extension
  pattern <- "\\.csv$"
  
  # In case we need to filter gcm
  if (!missing(gcm)) {
    pattern <- paste0("(", paste0(gcm, collapse = "|"), ").*", pattern)
  }
  files <- list.files(
    file.path(
      data_path(),
      getOption("climRpnw.gcm.path", default = "inputs_pkg/gcm")
    ),
    recursive = TRUE,
    full.names = TRUE,
    pattern = pattern
  )
  
  # Extract all different unique values
  list_unique(files, col_num)
}

#' List available global circulation models
#' @export
list_gcm <- function() {
  list.files(
    file.path(
      data_path(),
      getOption("climRpnw.gcm.path", default = "inputs_pkg/gcm")
    )
  )
}

#' List available shared socioeconomic pathways
#' @param gcm An optional character vector. Limit list to provided global circulation models.
#' @export
list_ssp <- function(gcm) {
  list_parse(gcm, 4)
}

#' List available period
#' @param gcm An optional character vector. Limit list to provided global circulation models.
#' @export
list_period <- function(gcm) {
  list_parse(gcm, 6:7)
}

#' List available runs
#' @param gcm An optional character vector. Limit list to provided global circulation models.
#' @export
list_run <- function(gcm) {
  list_parse(gcm, 5)
}