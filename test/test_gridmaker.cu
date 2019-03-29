#define BOOST_TEST_MODULE gridmaker_cuda_test
#include <boost/test/unit_test.hpp>
#include "grid_maker.h"
#include "atom_typer.h"
#include "test_util.h"
#include "example_extractor.h"
#include <iostream>
#include <iomanip>

#define TOL 0.0001f
using namespace libmolgrid;

BOOST_AUTO_TEST_CASE(forward_agreement) {
  size_t natoms = 1000;
  float resolution = 0.5; 
  float dimension = 23.5;
  float radiusmultiple = 1.5;
  GridMaker gmaker(resolution, dimension, radiusmultiple);
  float3 dim = gmaker.getGridDims();

  //randomly generated example, check equivalence between gpu and cpu versions
  random_engine.seed(0);
  MGrid2f coords(natoms, 3);
  MGrid1f type_indices(natoms); 
  MGrid1f radii(natoms);
  MGrid4f cout(dim.x, dim.y, dim.z, GninaIndexTyper::NumTypes);
  make_mol(coords.cpu(), type_indices.cpu(), radii.cpu(), natoms);
  float3 grid_center = make_float3(0,0,0); //coords generated from -25 to 25
                                           //so this should be ok

  //make grid
  std::fill(cout.data(), cout.data() + cout.size(), 0.0);
  gmaker.forward(grid_center, coords.cpu(), type_indices.cpu(), radii.cpu(), cout.cpu());

  Grid2fCUDA gcoords = coords.gpu();
  Grid1fCUDA gtype_indices = type_indices.gpu();
  Grid1fCUDA gradii = radii.gpu();
  size_t ntypes = GninaIndexTyper::NumTypes;
  size_t gsize = dim.x * dim.y * dim.z * ntypes;
  MGrid4f gout(dim.x, dim.y, dim.z, ntypes);
  LMG_CUDA_CHECK(cudaMemset(gout.data(), 0, gsize * sizeof(float)));
  gmaker.forward(grid_center, gcoords, gtype_indices, gradii, gout.gpu());
  cudaError_t error = cudaGetLastError();
  BOOST_CHECK_EQUAL(error, cudaSuccess);
  gout.tocpu();

  // std::ofstream out("out");
  // out.precision(5);
  // std::setprecision(5);
  //check equivalence
  for (size_t i=0; i<dim.x; ++i) {
    for (size_t j=0; j<dim.y; ++j) {
      for (size_t k=0; k<dim.z; ++k) {
        for (size_t ch=0; ch<GninaIndexTyper::NumTypes; ++ch) {
          // out << cout(i,j,k,ch);
          // out << " ";
          // out << gout(i,j,k,ch);
          // out << "\n";
          BOOST_CHECK_SMALL(cout(i,j,k,ch) - gout(i,j,k,ch), TOL);
        }
      }
    }
  }

  //check grid wasn't empty
  BOOST_CHECK_EQUAL(grid_empty(cout.cpu()), false);
  BOOST_CHECK_EQUAL(grid_empty(gout.cpu()), false);
}

BOOST_AUTO_TEST_CASE(forward_gpu) {
  // hard-coded example, compared with a reference
  // read in example
  ExampleRef exref("1 ../../test/data/REC.pdb ../../test/data/LIG.mol", 1);
  std::shared_ptr<FileMappedGninaTyper> rectyper = 
    std::make_shared<FileMappedGninaTyper>("../../test/data/gnina35.recmap");
  std::shared_ptr<FileMappedGninaTyper> ligtyper = 
    std::make_shared<FileMappedGninaTyper>("../../test/data/gnina35.ligmap");
  ExampleProviderSettings settings;
  ExampleExtractor extractor(settings, rectyper, ligtyper);
  Example ex;
  extractor.extract(exref, ex);
  CoordinateSet combined = ex.merge_coordinates();
  Grid2fCUDA coord = combined.coord.gpu();
  Grid1fCUDA type_index = combined.type_index.gpu();
  Grid1fCUDA radius = combined.radius.gpu();
  CoordinateSet coordgpu(coord, type_index, radius, combined.max_type);

  size_t ntypes = coordgpu.num_types();

  // set up gridmaker and run forward
  float dimension = 23.5;
  float resolution = 0.5;
  double half = dimension / 2.0;
  float3 grid_center = make_float3(-16.56986 + half, 0.63044 + half, -17.51435 + half);
  float grid_origin[3] = {-16.56986, 0.63044, -17.51435};
  GridMaker gmaker(resolution, dimension);
  float3 grid_dims = gmaker.getGridDims();
  MGrid4f out(grid_dims.x, grid_dims.y, grid_dims.z, ntypes);
  Grid4fCUDA gpu_grid = out.gpu();
  size_t gsize = grid_dims.x * grid_dims.y * grid_dims.z * ntypes;
  LMG_CUDA_CHECK(cudaMemset(gpu_grid.data(), 0, gsize * sizeof(float)));
  gmaker.forward(grid_center, coordgpu, gpu_grid);
  out.tocpu();

  // read in reference data
  std::vector<float> refdat;
  std::ifstream ref("../../test/data/RECLIG.48.35.binmap");
  BOOST_CHECK_EQUAL((bool)ref, true);
  while(ref && ref.peek() != EOF) {
    float nextval = 0;
    ref.read((char*)&nextval, sizeof(float));
    refdat.push_back(nextval);
  }
  Grid4f ref_grid(refdat.data(), grid_dims.x, grid_dims.y, grid_dims.z, ntypes);

  std::setprecision(5);
  // compare gridmaker result to reference
  for (size_t ch=0; ch<ntypes; ++ch) {
    std::string fname = "gpu_" + std::to_string(ch) + ".dx";
    std::ofstream fout(fname.c_str());
    fout.precision(5);
    unsigned n = grid_dims.x;
    fout.precision(5);
    fout << std::fixed;
    fout << "object 1 class gridpositions counts " << n << " " << n << " " << " "
        << n << "\n";
    fout << "origin";
    for (unsigned i = 0; i < 3; i++) {
      fout << " " << grid_origin[i];
    }
    fout << "\n";
    fout << "delta " << resolution << " 0 0\ndelta 0 " << resolution
        << " 0\ndelta 0 0 " << resolution << "\n";
    fout << "object 2 class gridconnections counts " << n << " " << n << " " << " "
        << n << "\n";
    fout << "object 3 class array type double rank 0 items [ " << n * n * n
        << "] data follows\n";
    unsigned total = 0;
    for (size_t i=0; i<grid_dims.x; ++i) {
      for (size_t j=0; j<grid_dims.y; ++j) {
        for (size_t k=0; k<grid_dims.z; ++k) {
          fout << out(ch,i,j,k);
          total++;
          if (total % 3 == 0)
            fout << "\n";
          else
            fout << " ";
          // BOOST_CHECK_SMALL(out(ch,i,j,k) - ref_grid(ch,i,j,k), TOL);
        }
      }
    }
  }
}