# Load libraries ----
packages <- c('tidyverse',
              'sf',
              'terra',
              'elevatr', 
              'dataRetrieval',
              'nhdplusTools',
              'StreamCatTools',
              'tmap',
              'climateR',
              'data.table',
              'mapview',
              'here',
              'furrr',
              'nngeo',
              'retry',
              'units',
              'FedData',
              'knitr',
              'DT')

# this package loader avoids unloading and reloading packages 
package_loader <- function(x) {
  if (!requireNamespace(x, quietly = TRUE)) {
    install.packages(x)
  }
  require(x, character.only = TRUE)
}

lapply(packages, package_loader)

# Load data thats getting tossed into this function ----
filtered_transbasin_watersheds <- read_rds(here("data", "watersheds_div.RDS")) %>% 
  filter(transbasin == "NATURAL")

# Define `get_historic_climate()` ----
# Function to download and process GridMET climate data for spatial features
# Downloads temperature (max/min), precipitation, and potential evapotranspiration
# Processes data into a standardized format with calculated values
get_historic_climate <- function(sf,
                                 col_name,
                                 start = "1979-01-01",
                                 end = "2023-12-31",
                                 vars = c("tmmx", "tmmn", "pr", "pet")) {
  
  # Rename the identifying column to a standard name for consistent joining
  sf <- sf %>%
    dplyr::rename("join_index" = {{col_name}})
  
  # Initialize list to store climate datat for each spatial feature
  all_climate_data <- vector("list", length = nrow(sf))
  
  # Ensure sf features are polygons
  if(any(unique(sf::st_geometry_type(sf)) %in% c("POLYGON", "MULTIPOLYGON"))){
    
    for (i in 1:nrow(sf)) {
      
      aoi <- sf[i,]
      
      print(paste0('Downloading GridMET for ', aoi$join_index, "."))
      
      # <<<< clim object is empty and gives me the strange error. >>>>
      # Retrieve climate data from GridMET for this feature
      clim <- climateR::getGridMET(AOI = aoi,
                                   varname = vars,
                                   startDate = start,
                                   endDate = end)
      
      # <<<< BROWSER CALL HERE TO DEBUG >>>> ----
      # When I am browsing this function and call clim I get an error thrown
      browser()
      
      
      # Check if returned data is in SpatRaster format
      if(inherits(clim[[1]], "SpatRaster")){
        
        clim_crs <- crs(clim[[1]])
        
        # Handle CRS mismatches between climate data and input features
        if(st_crs(clim[[1]]) != st_crs(sf)){
          # Transform feature to climate data CRS and crop/mask climate data to feature boundary
          clim <- clim %>%
            purrr::map(
              # getGridMET defaults AOI to bbox - so crop & mask results to actual feature boundary
              ~terra::crop(., st_transform(aoi, crs = clim_crs), mask = TRUE),
              crs = clim_crs)
        } else {
          # If CRS already matches, just crop/mask without transformation
          clim <- clim %>%
            purrr::map(
              ~terra::crop(., aoi, mask = TRUE),
              crs = clim_crs)
        }
        
        # Process climate data into a tidy dataframe
        all_climate_data[[i]] <- clim %>%
          # Convert raster to df with coordinates
          purrr::map_dfr(~ as.data.frame(., xy = TRUE)) %>%
          data.table() %>%
          # Reshape data from wide to long
          pivot_longer(-(x:y),
                       names_to = "var_temp",
                       values_to = "val") %>%
          separate_wider_delim(var_temp, "_", names = c("var", "date")) %>% # Split variable name from date
          drop_na(val) %>%
          group_by(x, y, date) %>%
          # Reshape back to wide format with clean variable names
          pivot_wider(names_from = "var", values_from = "val") %>%
          # Calculate derived variables and convert units
          dplyr::mutate(date = as.Date(date),
                        pet_mm = pet,                   # Potential evapotranspiration (mm)
                        ppt_mm = pr,                    # Precipitation (mm)
                        tmax_C = tmmx - 273.15,         # Convert max temp from Kelvin to Celsius
                        tmin_C = tmmn - 273.15,         # Convert min temp from Kelvin to Celsius
                        tmean_C = (tmax_C + tmin_C)/2,  # Calculate mean temperature
                        join_index = aoi$join_index) %>%
          dplyr::select(-c("tmmx", "tmmn", "pr", "pet"))
        
        # saveRDS(all_climate_data[[i]], here("data", "climate2", paste0(aoi$state, "_", aoi$join_index, ".RDS")))
        
      } else {
        # Handle case where climate data is returned as a single grid cell (point data)
        
        all_climate_data[[i]] <- clim %>%
          data.table() %>%
          # Clean variable names
          rename_with(~ str_split(.x, "_", n = 2) %>% map_chr(1)) %>%
          # Since point features only have one grid cell, manually add coordinates
          dplyr::mutate(x = sf::st_coordinates(aoi)[[1]],
                        y = sf::st_coordinates(aoi)[[2]]) %>%
          # Calculate derived variables as with polygon features
          dplyr::mutate(date = as.Date(date),
                        pet_mm = pet,
                        ppt_mm = pr,
                        tmax_C = tmmx - 273.15,
                        tmin_C = tmmn - 273.15,
                        tmean_C = (tmax_C + tmin_C)/2,
                        join_index = aoi$join_index) %>%
          dplyr::select(-c("tmmx", "tmmn", "pr", "pet"))
        
        # saveRDS(all_climate_data[[i]], here("data", "climate2", paste0(aoi$state, "_", aoi$join_index, ".RDS")))
        
      }
    }
    
    all_climate_data <- all_climate_data %>%
      bind_rows()
    
    # Rename the join_index column
    colnames(all_climate_data)[colnames(all_climate_data) == "join_index"] <- {{col_name}}
    
    return(all_climate_data)
    
  } else {
    stop("Your sf feature is neither a polygon nor point feature, or it needs to be made valid.")
  }
  
}

# Apply `get_historic_climate()` to `filtered_transbasin_watersheds` object
watershed_climate <- get_historic_climate(sf = filtered_transbasin_watersheds,
                                          col_name = "site_no", 
                                          # Snow persistence start
                                          start = "2001-01-01",
                                          # Snow persistence end
                                          end = "2020-12-31",
                                          vars = c("pet", "pr", "tmmn", "tmmx")) %>%
  group_by(site_no) %>% 
  summarize(pet_mm_2001_2020 = mean(pet_mm, na.rm = TRUE),
            ppt_mm_2001_2020 = mean(ppt_mm, na.rm = TRUE), 
            tmax_C_2001_2020 = mean(tmax_C, na.rm = TRUE), 
            tmin_C_2001_2020 = mean(tmin_C, na.rm = TRUE))
