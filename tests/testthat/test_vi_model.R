context("Model-specific variable importance")


# Helper function(s) from sparklyr tests ---------------------------------------

# See https://github.com/rstudio/sparklyr/blob/master/tests/testthat/helper-initialize.R
testthat_spark_connection <- function() {
  version <- Sys.getenv("SPARK_VERSION", unset = "2.3.0")
  spark_installed <- sparklyr::spark_installed_versions()
  if (nrow(spark_installed[spark_installed$spark == version, ]) == 0) {
    options(sparkinstall.verbose = TRUE)
    sparklyr::spark_install(version)
  }
  connected <- FALSE
  if (exists(".testthat_spark_connection", envir = .GlobalEnv)) {
    sc <- get(".testthat_spark_connection", envir = .GlobalEnv)
    connected <- sparklyr::connection_is_open(sc)
  }
  if (!connected) {
    config <- sparklyr::spark_config()
    options(sparklyr.sanitize.column.names.verbose = TRUE)
    options(sparklyr.verbose = TRUE)
    options(sparklyr.na.omit.verbose = TRUE)
    options(sparklyr.na.action.verbose = TRUE)
    sc <- sparklyr::spark_connect(master = "local", version = version,
                                  config = config)
    assign(".testthat_spark_connection", sc, envir = .GlobalEnv)
  }
  get(".testthat_spark_connection", envir = .GlobalEnv)
}

# h2o setup
library(h2o)
h2o.init()
h2o.no_progress()

# Function to bin a numeric vector
bin <- function(x, num_bins) {
  quantiles <- quantile(x, probs = seq(from = 0, to = 1, length = num_bins + 1))
  bins <- cut(x, breaks = quantiles, label = FALSE, include.lowest = TRUE)
  as.factor(paste0("class", bins))
}

# Simulate Friedman's data
set.seed(101)  # for reproducibility
friedman1 <- friedman2 <- friedman3 <-
  as.data.frame(mlbench::mlbench.friedman1(1000, sd = 0.1))
friedman2$y <- bin(friedman1$y, num_bins = 2)
friedman3$y <- bin(friedman1$y, num_bins = 3)

# sparklyr setup
library(sparklyr)
sc <- testthat_spark_connection()
friedman1_tbl <- sdf_copy_to(sc, x = friedman1, name = "friedman1",
                             overwrite = TRUE)
friedman2_tbl <- sdf_copy_to(sc, x = friedman2, name = "friedman2",
                             overwrite = TRUE)

# Function to run checks for `vi_model()`
check_vi_model <- function(FUN, args, pkg = "", error_msg = "", ...) {

  # Check for package
  if (nzchar(pkg)) {
    skip_if_not_installed(pkg)
  }

  # Fit model
  FUN <- match.fun(FUN)
  fit <- do.call(FUN, args)
  # print(vip(fit))

  # Expectations
  if (!nzchar(error_msg)) {
    expect_silent(vis <- vi_model(fit, ...))
    expect_is(vis, class = c("vi", "tbl_df", "tbl", "data.frame"))
    expect_true(all(names(vis) %in% c("Variable", "Importance", "Sign")))
    expect_identical(ncol(friedman1) - 1L, nrow(vis))
  } else {
    expect_error(vi_model(fit, ...), regexp = error_msg, fixed = TRUE)
  }

}


test_that("The default method works for unsupported objects.", {

  # Skips
  skip_on_cran()

  # Run checks
  x <- pi
  class(x) <- "Chuck Norris"
  expect_error(vi_model(x))

})


# Package: C50 -----------------------------------------------------------------

test_that("`vi_model()` works for \"C50\" objects", {

  # Skips
  skip_on_cran()

  # Cycle through variable importance types
  for (type in c("usage", "splits")) {

    # Run checks
    check_vi_model(
      FUN = C50::C5.0,
      args = list(y ~ ., data = friedman2),
      pkg = "C50",
      type = type
    )

  }

})


# Package: caret ---------------------------------------------------------------

test_that("`vi_model()` works for \"train\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = caret::train,
    args = list(y ~ ., data = friedman1, method = "lm"),
    pkg = "caret"
  )

})


# Package: Cubist --------------------------------------------------------------

test_that("`vi_model()` works for \"cubist\" objects", {

  # Skips
  skip_on_cran()

  # Run checks (without specified weights)
  check_vi_model(
    FUN = Cubist::cubist,
    args = list(
      x = model.matrix(~ . - y - 1, data = friedman1),
      y = friedman1$y,
      committees = 10
    ),
    pkg = "Cubist"
  )

  # Run checks (with specified weights)
  check_vi_model(
    FUN = Cubist::cubist,
    args = list(
      x = model.matrix(~ . - y - 1, data = friedman1),
      y = friedman1$y,
      committees = 10
    ),
    pkg = "Cubist",
    weights = c(0.1, 0.9)
  )

})


# Package: earth ---------------------------------------------------------------

test_that("`vi_model()` works for \"earth\" objects", {

  # Skips
  skip_on_cran()

  # Cycle through variable importance types
  for (type in c("nsubsets", "rss", "gcv")) {

    # Run checks
    check_vi_model(
      FUN = earth::earth,
      args = list(y ~ ., data = friedman1, degree = 2),
      pkg = "earth",
      type = type
    )

  }

})


# Package: gbm -----------------------------------------------------------------

test_that("`vi_model()` works for \"gbm\" objects", {

  # Skips
  skip_on_cran()

  # Cycle through variable importance types
  for (type in c("relative.influence", "permutation")) {

    # Run checks
    check_vi_model(
      FUN = gbm::gbm,
      args = list(
        y ~ .,
        data = friedman1,
        distribution = "gaussian",
        n.trees = 1000,
        interaction.depth = 5,
        shrinkage = 0.1,
        bag.fraction = 1
      ),
      pkg = "gbm",
      type = type
    )

  }

})


# Package: glmnet --------------------------------------------------------------

test_that("`vi_model()` works for \"glmnet\" objects", {

  # Skips
  skip_on_cran()

  # Run checks (without specified lambda)
  check_vi_model(
    FUN = glmnet::glmnet,
    args = list(
      x = model.matrix(~ . - y - 1, data = friedman1),
      y = friedman1$y
    ),
    pkg = "glmnet"
  )

  # Run checks (with specified lambda)
  check_vi_model(
    FUN = glmnet::glmnet,
    args = list(
      x = model.matrix(~ . - y - 1, data = friedman1),
      y = friedman1$y
    ),
    pkg = "glmnet",
    s = 0.01
  )

})


test_that("`vi_model()` works for \"cv.glmnet\" objects", {

  # Skips
  skip_on_cran()

  # Run checks (without specified lambda)
  check_vi_model(
    FUN = glmnet::cv.glmnet,
    args = list(
      x = model.matrix(~ . - y - 1, data = friedman1),
      y = friedman1$y
    ),
    pkg = "glmnet"
  )

  # Run checks (with specified lambda)
  check_vi_model(
    FUN = glmnet::cv.glmnet,
    args = list(
      x = model.matrix(~ . - y - 1, data = friedman1),
      y = friedman1$y
    ),
    pkg = "glmnet",
    s = 0.01
  )

})


# Package: h2o -----------------------------------------------------------------

test_that("`vi_model()` works for \"H2OBinomialModel\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = h2o::h2o.randomForest,
    args = list(
      x = paste0("x.", 1:10),
      y = "y",
      training_frame = h2o::as.h2o(friedman2),
      ntrees = 50L,
      seed = 101
    ),
    pkg = "h2o"
  )

})

test_that("`vi_model()` works for \"H2OMultinomialModel\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = h2o::h2o.randomForest,
    args = list(
      x = paste0("x.", 1:10),
      y = "y",
      training_frame = h2o::as.h2o(friedman3),
      ntrees = 50L,
      seed = 101
    ),
    pkg = "h2o"
  )

})

test_that("`vi_model()` works for \"H2ORegressionModel\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = h2o::h2o.randomForest,
    args = list(
      x = paste0("x.", 1:10),
      y = "y",
      training_frame = h2o::as.h2o(friedman1),
      ntrees = 50,
      seed = 101
    ),
    pkg = "h2o"
  )

})


# Package: neuralnet -----------------------------------------------------------

test_that("`vi_model()` works for \"neuralnet\" objects", {

  # Skips
  skip_on_cran()
  skip_if_not_installed("NeuralNetTools")

  # Cycle through variable importance types
  for (type in c("olden", "garson")) {

    # Run checks
    check_vi_model(
      FUN = neuralnet::neuralnet,
      args = list(y ~ ., data = data.matrix(friedman1)),
      pkg = "neuralnet",
      type = type
    )

  }

})


# Package: nnet ----------------------------------------------------------------

test_that("`vi_model()` works for \"nnet\" objects", {

  # Skips
  skip_on_cran()
  skip_if_not_installed("NeuralNetTools")

  # Cycle through variable importance types
  for (type in c("olden", "garson")) {

    # Run checks
    check_vi_model(
      FUN = nnet::nnet,
      args = list(
        y ~ .,
        data = friedman1,
        size = 10,
        linout = TRUE,
        decay = 0.1,
        maxit = 1000,
        trace = FALSE
      ),
      pkg = "nnet",
      type = type
    )

  }

})


# Package: party ---------------------------------------------------------------

test_that("`vi_model()` works for \"RandomForest\" objects", {

  # Skips
  skip_on_cran()

  # Cycle through variable importance types
  for (type in c("accuracy", "auc")) {

    # Run checks
    check_vi_model(
      FUN = party::cforest,
      args = list(
        y ~ .,
        data = friedman1,
        controls = party::cforest_unbiased(ntree = 50)
      ),
      pkg = "party"
    )

  }

})


# Package: partykit ------------------------------------------------------------

test_that("`vi_model()` works for \"constparty\" objects", {

  # Skips
  skip_on_cran()

  # Run checks (without specified weights)
  check_vi_model(
    FUN = partykit::ctree,
    args = list(y ~ ., data = friedman1),
    pkg = "partykit"
  )

})

test_that("`vi_model()` works for \"cforest\" objects", {

  # Skips
  skip_on_cran()

  # Run checks (without specified weights)
  check_vi_model(
    FUN = partykit::cforest,
    args = list(y ~ ., data = friedman1, ntree = 50L),
    pkg = "partykit"
  )

})


# Package: pls -----------------------------------------------------------------

test_that("`vi_model()` works for \"mvr\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = pls::plsr,
    args = list(y ~ ., data = friedman1),
    pkg = "pls"
  )

})


# Package: randomForest --------------------------------------------------------

test_that("`vi_model()` works for \"randomForest\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = randomForest::randomForest,
    args = list(y ~ ., data = friedman1, ntree = 50),
    pkg = "randomForest"
  )

})


# Package: ranger --------------------------------------------------------------

test_that("`vi_model()` works for \"ranger\" objects", {

  # Skips
  skip_on_cran()

  # Cycle through variable importance types
  for (type in c("impurity", "impurity_corrected", "permutation")) {

    # Run checks
    check_vi_model(
      FUN = ranger::ranger,
      args = list(
        y ~ .,
        data = friedman1,
        num.trees = 50,
        importance = type
      ),
      pkg = "nnet"
    )

  }

})


# Package: rpart ---------------------------------------------------------------

test_that("`vi_model()` works for \"rpart\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = rpart::rpart,
    args = list(y ~ ., data = friedman1),
    pkg = "rpart"
  )

})


# Package: RSNNS ---------------------------------------------------------------

test_that("`vi_model()` works for \"RSNNS\" objects", {

  # Skips
  skip_on_cran()
  skip_if_not_installed("NeuralNetTools")

  # Cycle through variable importance types
  for (type in c("olden", "garson")) {

    # Run checks
    check_vi_model(
      FUN = RSNNS::mlp,
      args = list(
        x = model.matrix(~ . - y - 1, data = friedman1),
        y = friedman1$y,
        size = 5,
        linOut = TRUE
      ),
      pkg = "RSNNS",
      type = type
    )

  }

})


# Package: sparklyr ------------------------------------------------------------

test_that("`vi_model()` works for \"ml_model_decision_tree_classification\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = sparklyr::ml_decision_tree,
    args = list(
      x = friedman1_tbl,
      formula = y ~ .,
      type = "regression"
    ),
    pkg = "sparklyr"
  )

})


test_that("`vi_model()` works for \"ml_model_decision_tree_regression\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = sparklyr::ml_decision_tree,
    args = list(
      x = friedman2_tbl,
      formula = y ~ .,
      type = "classification"
    ),
    pkg = "sparklyr"
  )

})


test_that("`vi_model()` works for \"ml_model_gbt_regression\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = sparklyr::ml_gradient_boosted_trees,
    args = list(
      x = friedman1_tbl,
      formula = y ~ .,
      type = "regression",
      max_iter = 50
    )
  )

})


test_that("`vi_model()` works for \"ml_model_gbt_classification\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = sparklyr::ml_gradient_boosted_trees,
    args = list(
      x = friedman2_tbl,
      formula = y ~ .,
      type = "classification"
    ),
    pkg = "sparklyr"
  )

})


test_that("`vi_model()` works for \"ml_model_generalized_linear_regression\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = sparklyr::ml_generalized_linear_regression,
    args = list(
      x = friedman2_tbl,
      formula = y ~ .
    ),
    pkg = "sparklyr"
  )

})


test_that("`vi_model()` works for \"ml_model_linear_regression\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = sparklyr::ml_linear_regression,
    args = list(
      x = friedman1_tbl,
      formula = y ~ .
    ),
    pkg = "sparklyr"
  )

})


test_that("`vi_model()` works for \"ml_model_random_forest_regression\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = sparklyr::ml_random_forest,
    args = list(
      x = friedman1_tbl,
      formula = y ~ .,
      type = "regression",
      num_trees = 50
    ),
    pkg = "sparklyr"
  )

})


test_that("`vi_model()` works for \"ml_model_random_forest_classification\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = sparklyr::ml_random_forest,
    args = list(
      x = friedman2_tbl,
      formula = y ~ .,
      type = "classification",
      num_trees = 50
    ),
    pkg = "sparklyr"
  )

})


# Package: stats ---------------------------------------------------------------

test_that("`vi_model()` works for \"glm\" objects", {

  # Skips
  skip_on_cran()

  # Run checks (t-statistic)
  check_vi_model(
    FUN = stats::glm,
    args = list(y ~ ., data = friedman1),
    pkg = "stats"
  )

  # Run checks (z-statistic)
  check_vi_model(
    FUN = stats::glm,
    args = list(y ~ ., data = friedman2, family = binomial),
    pkg = "stats"
  )

})


test_that("`vi_model()` works for \"lm\" objects", {

  # Skips
  skip_on_cran()

  # Run checks
  check_vi_model(
    FUN = stats::lm,
    args = list(y ~ ., data = friedman1),
    pkg = "stats"
  )

})

test_that("`type` parameter returns proper values", {

  # Skips
  skip_on_cran()

  X <- scale(mtcars[, -1])
  Y <- mtcars$mpg
  lm_model <- lm(Y ~ X)

  # Run checks
  coefs <- summary(lm_model)[["coefficients"]][-1, ]
  t_stat <- vi_model(lm_model)
  raw <- vi_model(lm_model, type = "raw")

  expect_equal(as.vector(abs(coefs[, "t value"])), t_stat$Importance)
  expect_equal(as.vector(abs(coefs[, "Estimate"])), raw$Importance)

})


# Package: xgboost -------------------------------------------------------------

test_that("`vi_model()` works for \"xgboost\" objects", {

  # Skips
  skip_on_cran()

  # Cycle through variable importance types
  for (type in c("gain", "cover", "frequency")) {

    # Run checks
    check_vi_model(
      FUN = xgboost::xgboost,
      args = list(
        data = model.matrix(~ . - y - 1, data = friedman1),
        label = friedman1$y,
        nrounds = 50,
        params = list(eta = 0.1),
        verbose = 0,
        save_period = 0
      ),
      pkg = "xgboost",
      type = type
    )

  }

})

# parsnip package interface ----------------------------------------------------

test_that("`vi_model()` works with parsnip objects", {

  # Skips
  skip_on_cran()

  set.seed(363)
  lm_mod <- lm(mpg ~ ., data = mtcars)
  mod_vi <- vi(lm_mod)

  parsnip <- list(fit = lm_mod)
  class(parsnip) <- c("linear_reg", "model_fit")
  expect_equal(mod_vi, vi(parsnip))
})


