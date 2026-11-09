from django.urls import path
urlpatterns = [
    path('users/<int:pk>/', views.user),
]
