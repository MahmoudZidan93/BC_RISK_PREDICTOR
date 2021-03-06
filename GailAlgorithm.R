source("AlgorithmUtil.R")

superapply = function(df, FUN) {
  args=list(FUN=FUN)
  args=append(args,Map(function(c) df[,c], colnames(df)))
  do.call( mapply, args )
}

gail_fields = c("AGE", "AGE_AT_MENARCHE", "BIOPSY","PARITY", "AGE_AT_FIRST_BIRTH", "FIRST_DEGREE_RELATIVES")

# Converts our input to the format used in Gail papers
gail_avatars = function(avatars) {
  # Convert to gail format. 

  AGECAT = (avatars$AGE >= 50) + 0
  AGEMEN = ifelse(avatars$AGE_AT_MENARCHE >= 14, 0,
                  ifelse(avatars$AGE_AT_MENARCHE < 12, 2, 1) 
                  )
  NBIOPS = ifelse(avatars$BIOPSY == 0, 0,
                  ifelse(avatars$BIOPSY == 1, 1, 2))
  AGEFLB = ifelse(!avatars$PARITY, 2, 
                  ifelse(avatars$AGE_AT_FIRST_BIRTH < 20, 0,
                         ifelse(avatars$AGE_AT_FIRST_BIRTH >= 20 &
                                avatars$AGE_AT_FIRST_BIRTH <  25, 1,
                                ifelse(avatars$AGE_AT_FIRST_BIRTH >= 25 &
                                       avatars$AGE_AT_FIRST_BIRTH <  30, 2, 3
                                       )))) 

  NUMREL = ifelse(avatars$FIRST_DEGREE_RELATIVES == 0, 0,
                  ifelse(avatars$FIRST_DEGREE_RELATIVES == 1, 1, 2))

  # which are multiplied by these vars (AGE = 1)
  data.frame(AGECAT, AGEMEN, NBIOPS, AGEFLB, NUMREL)
}

# Takes avatars and a fit (or fit finding function) and returns a three column matrix with:
#  RR: avatars relative risk at current age
#  RR_LT_50: avatars relative relative risk for ages younger than 50
#  RR_GTE_50: avatars relative relative risk for ages 50 or older
gail_rr = function(avatars, fit = Gail89){
  # if avatar's are not in Gail format, convert it
#   if(!all(c("AGECAT", "AGEMEN", "NBIOPS","AGEFLB", "NUMREL") %in% colnames(avatars))) {
#  }

  # if we have fit finder, run avatars one-by-one
  if(is.function(fit)) {
    rrs = t(mapply(function(i) {
      my_fit = do.call(fit, as.list(avatars[i,]))
      gail_rr(avatars[i,], my_fit)
    }, 1:nrow(avatars)))

    colnames(rrs) <- c("RR", "RR_LT_50", "RR_GTE_50")

    return(rrs)
  }

  # AGECAT = 0 

  var = rbind(
           0 # intercept
         , avatars$AGEMEN
         , avatars$NBIOPS
         , avatars$AGEFLB
         , avatars$NUMREL
         , 1 # AGECAT
         , avatars$NBIOPS # * AGECAT
         , avatars$AGEFLB * avatars$NUMREL
         )

  RR_LT_50  = exp(apply((fit$cof * c(0,1,1,1,1,0,0,1) * var), 2, sum))
  # AGECAT = 1 
  RR_GTE_50 = exp(apply((fit$cof * c(0,1,1,1,1,1,1,1) * var), 2, sum))

  RR = ifelse(avatars$AGECAT, RR_GTE_50, RR_LT_50)


  if("HYPERPLASIA" %in% colnames(avatars)) {
    h = avatars$HYPERPLASIA
    hyperplasia = ifelse(is.na(h), 1, ifelse(h, 1.82, 0.93))
  } else {
    hyperplasia = 1
  }


  cbind(RR, RR_LT_50, RR_GTE_50) * hyperplasia
}


# Modifies hazard matrix for cutpoints at intervals corresponding to target
# age. This way we can calculate hazards for patients whose age is not a 
# multiple of 5.
hazard_splice = function(hazards, years) {
  cuts = hazards$cutpoints
  total_width = cuts[length(cuts)] + hazards$width[nrow(hazards)]

  cuts = append(cuts, total_width)

  if(any(years > total_width)) {
    warning("Projecting risk too far into future.")
    years = years[years <= total_width]
  }

  new_cuts = unique(sort(append(hazards$cutpoints, years)))
  trans = cut(new_cuts, breaks=cuts, right=FALSE, include.lowest=FALSE)

  new_h = hazards[as.numeric(trans),]
  new_h$cutpoints = new_cuts
  new_widths = append(new_cuts[-1], total_width) - new_cuts
  new_h$width = new_widths

  new_h
}


# Projected Absolute Risk
gail_relative_risk_to_absolute_risk = function( age, years, rr_lt_50, rr_gte_50, hazards) {
  hazards = hazard_splice(hazards, append(age,age+years))
  h1 = hazards$h1_star * hazards$F
  h2 = hazards$h2
  cutpts = hazards$cutpoints
  widths = hazards$width
  rr = ifelse(cutpts < 50, rr_lt_50, rr_gte_50)

  cuts = hazards$cutpoints
  total_width = cuts[length(cuts)] + hazards$width[nrow(hazards)]
  cuts = unique(append(cuts, total_width))

  cut_f = function(x) {
    cut(x, breaks=cuts, right=FALSE, include.lowest=FALSE)
  }

  age_index = as.numeric(cut_f(age))

  # tbl = data.frame(levels(age_index), rr, h1, h2, widths)
  # print(tbl)


  S1_t = cumprod(exp(-1 * h1 * rr * widths))
  S2_t = cumprod(exp(-1 * h2      * widths))

  S1_t=append(1,S1_t)[1:length(h1)]
  S2_t=append(1,S2_t)[1:length(h1)]

  S1_a = S1_t[age_index]
  S2_a = S2_t[age_index]


  five_year_risks = cumsum(
       (1:(length(h1)) >= (age_index))
     * (h1 * rr) / (h1 * rr + h2)
     * (S1_t / S1_a)
     * (S2_t / S2_a)
     * (1 - exp( -1 * widths * (h1 * rr + h2)))
     )

#  print(five_year_risks)
  # returns list of 5-year risks

  five_year_risks[as.numeric(cut_f(age+years-1))]
}

# Performs the Gail Algorithm (old-school gail89 by default).
gail_algorithm = function( avatars              # DF of avatars
                         , years  = c(5,10,15)  # Years to Calculate Absolute Risk On
                         , fit    = gail89      # Fit finding function (e.g. ``)
                         , aux_rr = NULL        # auxilary relative risk function
                         ) {

  avatars = cbind(avatars, gail_avatars(avatars))

  if(!is.null(aux_rr)) {
    if(is.function(aux_rr)) {
      aux_rr = aux_rr(avatars)
    } else if(length(aux_rr) == nrow(avatars)) {
      aux_rr = aux_rr
    } else {
      stop("aux_rr invalid")
    }
  } else {
    aux_rr = 1;
  }

  # calculate the relative risks 
  relative_risks = gail_rr(avatars, fit) * aux_rr 
  absolute_risks = as.matrix(mapply(
    function(i, AGE, RR_LT_50, RR_GTE_50) {
      if(is.function(fit)) {
        # single row fetching really slows things down
        # can't think of a better way 
        fit = do.call(fit, as.list(avatars[i,]))
      }
      gail_relative_risk_to_absolute_risk(
        AGE
      , years
      , RR_LT_50
      , RR_GTE_50
      , fit$hazards
      )
    }, 1:nrow(avatars), avatars$AGE,
      relative_risks[,"RR_LT_50"], relative_risks[,"RR_GTE_50"]))

  if(length(years) > 1) {
    absolute_risks = t(absolute_risks)
  }
  colnames(absolute_risks) = paste("AR", years, sep="_")


  cbind(relative_risks, absolute_risks)

}
