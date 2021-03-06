#' Make superensemble
#'
#' Fit a superensemble model with a simulated dataset. Note that this will take
#' a few minutes to run.
#'
#' @param cores Number of cores to use
#' @param ntree Number of trees. Passed to
#'   \code{\link[randomForest]{randomForest}}.^
#' @param formula Specify the formula used in the random forest model
#' @param type Which type of ensemble model to build. Types are rf (random
#'   forest), gbm (GBM), lm (linear regression). Note that in the case of linear
#'   regression you may want to specify the formula to include interactions. For
#'   example, to include all 2-way interactions: \code{log(bbmsy_true_mean) ~
#'   (CMSY + COMSIR + Costello + SSCOM + spec_freq_0.05 + spec_freq_0.2)^2}
#' @importFrom dplyr arrange_ group_by_ do rename_ mutate_ select_ inner_join
#'   left_join "%>%" summarise_
#' @importFrom stats approx na.omit spec.ar
#' @return A list with two elements: \code{model} contains a model from the
#'   package \pkg{randomForest} and \code{data} contains the data used to fit
#'   the model.
#' @export
#' @examples
#' \dontrun{
#'   x <- make()
#'   randomForest::partialPlot(x$model, x.var = "CMSY", pred.data = x$data)
#' }

make <- function(ntree = 1000, cores = 2,
  formula = log(bbmsy_true_mean) ~ CMSY + COMSIR + Costello + SSCOM +
    spec_freq_0.05 + spec_freq_0.2,
  type = c("rf", "gbm", "lm")) {
  #Add spectral frequencies to simulated data
  #make spectral data

  type <- type[[1]]
  assertthat::assert_that(is.character(type))
  assertthat::assert_that(type %in% c("rf", "gbm", "lm"))

  dsim <- dsim %>% dplyr::mutate(stock_id = paste(stock_id, iter, sigmaC, sigmaR))
  dsim <- dsim[!duplicated(dplyr::select(dsim, stock_id, year, method_id)), ]

  dsim_spec<- dsim %>%
    dplyr::filter(method_id == "SSCOM") %>% # pick one
    arrange_(~stock_id, ~year) %>%
    group_by_(~stock_id, ~sigmaC, ~sigmaR, ~LH, ~iter, ~ED) %>%
    do(train_spec_mat(.$catch)) %>%
    rename_(spec_freq = ~x, spec_dens = ~y) %>%
    as.data.frame()

  dsim_spec$spec_freq <- paste0("spec_freq_", dsim_spec$spec_freq)
  dsim_spec_wide <- reshape2::dcast(dsim_spec,
    stock_id + sigmaC + sigmaR + LH + iter + ED ~ spec_freq,
    value.var = "spec_dens")

  #adding sims data and spec data together for training model
  dsim <- suppressWarnings(left_join(dsim, dsim_spec_wide)) # warnings on character-factor conversions
  dsim$method_id <- sub("COM.SIR", "COMSIR", dsim$method_id) # to match RAM fits

  dsim <- dsim %>%
    arrange_(~stock_id, ~iter, ~year) # critical since not all in order

  doParallel::registerDoParallel(cores = cores)

  dsim_sum <- plyr::ddply(dsim, c("stock_id", "method_id", "iter"),
    .parallel = TRUE, .fun = mean_bbmsy)
  # saveRDS(dsim_sum, file = "generated-data/dsim_sum.rds")
  # dsim_sum <- readRDS("generated-data/dsim_sum.rds")

  # join in some characteristics that we'll use in models:
  dsim_meta <- dsim %>%
    group_by_(~stock_id, ~iter, ~method_id) %>%
    summarise_(
      spec_freq_0.05 = ~spec_freq_0.05[1],
      spec_freq_0.2 = ~spec_freq_0.2[1])
  dsim_sum <- inner_join(dsim_sum, dsim_meta)

  # save a data frame of 'true' operating model values to merge in:

  trues <- select_(dsim_sum, ~stock_id, ~iter, ~method_id, ~bbmsy_true_mean)
  trues <- trues[which(trues$method_id == "SSCOM"), ]
  trues <- select_(trues, ~stock_id, ~iter, ~bbmsy_true_mean)
  trues <- trues[!duplicated(trues), ] # one value per operating model stockid

  assertthat::assert_that(identical(nrow(trues), length(unique(dsim$stock_id))))

  # switch from long to wide format for modelling:
  d_mean_sim <- reshape2::dcast(dsim_sum,
    stock_id + iter + spec_freq_0.05 + spec_freq_0.2 ~ method_id,
    value.var = "bbmsy_est_mean")  %>%
    inner_join(trues)

  assertthat::assert_that(identical(nrow(d_mean_sim), length(unique(dsim$stock_id))))

  #Train random forest ensemble model with simulated data
  d_mean_sim <- na.omit(d_mean_sim)

  if (type == "rf") {
    m <- randomForest::randomForest(formula = formula,
      data = d_mean_sim, ntree = ntree)
  }
  if (type == "gbm") {
    m <- gbm::gbm(formula = formula,
      data = d_mean_sim, distribution = "gaussian",
      n.trees = 2000L, interaction.depth = 6, shrinkage = 0.01)
  }
  if (type == "lm") {
    m <- stats::lm(formula = formula, data = d_mean_sim)
  }
  list(model = m, data = d_mean_sim)
}

mean_bbmsy <- function(dat, years_window = 5L) {
  # chunk of data must have columns: b_bmsy_true, b_bmsy_est
  if (ncol(dat) > 0) {
    if (nrow(dat) > years_window) { # some have 3 years??
      .n <- nrow(dat)
      i <- seq(.n-(years_window-1), .n)
      bbmsy_true_mean = mean(dat$b_bmsy_true[i])
      bbmsy_est_mean = mean(dat$b_bmsy_est[i])
      ytrue <- dat$b_bmsy_true[i]
      yest <- dat$b_bmsy_est[i]
      data.frame(bbmsy_true_mean, bbmsy_est_mean)
    }
  }
}

#Calculate Spectral frequencies for the regional data
train_spec_mat <- function(x, freq_vec = 1/c(5, 20)) {
  # using AR as smoother, empirical didn't seem to confer much more benefit
  if(length(x) >= 10) {
    sp <- spec.ar(x/max(x), plot = FALSE)
    # approximate at fixed frequencies - necessary as series of different length
    as.data.frame(approx(x = sp$freq, y = sp$spec, xout = freq_vec))
  } else {
    data.frame(x=NA, y=NA, xout=NA)
  }
}
